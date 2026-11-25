import UIKit
import SwiftUI
import Combine
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

/// An SSH terminal window: SwiftTerm draws the terminal, Citadel carries the SSH session.
///
/// Stock iOS has no local shell (no fork/exec), so the terminal is an SSH client: connect to a PC,
/// a server, or WSL on the same machine. Everything is driven by iDesk's own keyboard routing — the
/// desktop's touch shield means text fields and the terminal view never become first responder, so
/// typing arrives through DesktopModel.send / sendKey and the session echoes prompts itself.
final class TerminalSession: ObservableObject {
    /// Where the session is: choosing a mode, asking for SSH details, connecting, or live.
    enum Stage: Equatable {
        case pickMode, askHost, askUser, askPass, connecting, connected, closed
    }
    /// Local = Alpine Linux running on the phone (embedded iSH-ARM64); ssh = a PC / server.
    enum Mode { case local, ssh }
    @Published private(set) var stage: Stage = .pickMode
    private var mode: Mode = .ssh

    let terminalView: TerminalView
    /// Non-nil when this window reattached to a local session another window booted: the engine
    /// owns that session's view, so this window shows and sizes that view instead.
    private var attached: TerminalSession?
    /// The view this window actually shows.
    var displayView: TerminalView { attached?.terminalView ?? terminalView }
    /// The SSH client, boxed so a nonisolated deinit can close it (Swift 6 deinit rules).
    private final class ConnBox: @unchecked Sendable { var client: SSHClient? }
    private let connBox = ConnBox()
    private var stdin: TTYStdinWriter?
    private var lastCols = 80, lastRows = 24

    private var host = "", user = "", pass = "", port = 22
    /// The line being typed while answering a prompt.
    private var draft = ""

    init() {
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminalView = TerminalView(frame: .zero, font: font)
        terminalView.isUserInteractionEnabled = false   // iDesk's shield owns all touches
        terminalView.nativeBackgroundColor = UIColor(white: 0.08, alpha: 1)
        terminalView.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        host = UserDefaults.standard.string(forKey: Keys.host) ?? ""
        user = UserDefaults.standard.string(forKey: Keys.user) ?? ""
        banner()
    }

    private func banner() {
        feedText("iDesk Terminal\r\n\r\n")
        if LocalShell.session != nil {
            feedText("  1. Local   resume the Alpine session already running\r\n")
            feedText("  2. SSH     your PC, server or WSL (full speed)\r\n")
            feedText("  R. Reset   kill the stuck local session and boot fresh\r\n\r\n")
            feedText("Type 1, 2 or R: ")
        } else {
            feedText("  1. Local   Alpine Linux on this device (slower, works offline)\r\n")
            feedText("  2. SSH     your PC, server or WSL (full speed)\r\n\r\n")
            feedText("Type 1 or 2: ")
        }
    }

    private enum Keys {
        static let host = "iDesk.terminal.host"
        static let user = "iDesk.terminal.user"
    }

    // MARK: Prompts

    private func startSSH() {
        mode = .ssh
        feedText("\r\n\u{1B}[1mSSH mode.\u{1B}[0m Host keys are not verified (private use).\r\n\r\n")
        askHost()
    }

    private func askHost() {
        stage = .askHost
        draft = ""
        feedText(host.isEmpty ? "Host: " : "Host [\(host)]: ")
    }
    private func askUser() {
        stage = .askUser
        draft = ""
        feedText(user.isEmpty ? "Username: " : "Username [\(user)]: ")
    }
    private func askPass() {
        stage = .askPass
        draft = ""
        feedText("Password: ")
    }

    private func feedText(_ s: String) { displayView.feed(text: s) }

    /// A visible error, then Enter starts over.
    private func fail(_ message: String) {
        stage = .closed
        feedText("\r\n\u{1b}[31m" + message + "\u{1b}[0m\r\nPress Enter to try again.\r\n")
    }

    // MARK: Input from iDesk's keyboard routing

    /// Ordinary typed text.
    func sendText(_ s: String) {
        switch stage {
        case .connected:
            write(s.replacingOccurrences(of: "\n", with: "\r"))
        case .pickMode:
            if s == "1" { startLocal() }
            else if s == "2" { startSSH() }
            else if (s == "r" || s == "R"), LocalShell.session != nil { resetLocal() }
        case .askHost, .askUser:
            draft += s
            feedText(s)
        case .askPass:
            draft += s
            feedText(String(repeating: "*", count: s.count))
        case .connecting, .closed:
            break
        }
    }

    func keyBackspace() {
        switch stage {
        case .connected:
            write("\u{7f}")
        case .askHost, .askUser, .askPass:
            guard !draft.isEmpty else { return }
            draft.removeLast()
            feedText("\u{8}\u{20}\u{8}")        // erase the echoed character
        case .pickMode, .connecting, .closed:
            break
        }
    }

    func keyEnter() {
        switch stage {
        case .pickMode:
            break
        case .askHost:
            if !draft.isEmpty { host = draft }
            // "host:port" also names the port.
            if let colon = host.lastIndex(of: ":"), colon != host.startIndex,
               let p = Int(host[host.index(after: colon)...]) {
                port = p
                host = String(host[host.startIndex..<colon])
            }
            UserDefaults.standard.set(host, forKey: Keys.host)
            feedText("\r\n")
            askUser()
        case .askUser:
            if !draft.isEmpty { user = draft }
            UserDefaults.standard.set(user, forKey: Keys.user)
            feedText("\r\n")
            askPass()
        case .askPass:
            pass = draft
            draft = ""
            feedText("\r\n")
            connect()
        case .connected:
            write("\r")
        case .closed:
            feedText("\r\n")
            stage = .pickMode
            banner()
        case .connecting:
            break
        }
    }

    /// Arrows, Escape and friends: the escape sequences a shell expects.
    func keySpecial(_ key: String) {
        guard stage == .connected else { return }
        switch key {
        case "ArrowUp": write("\u{1b}[A")
        case "ArrowDown": write("\u{1b}[B")
        case "ArrowRight": write("\u{1b}[C")
        case "ArrowLeft": write("\u{1b}[D")
        case "Escape": write("\u{1b}")
        case "Tab": write("\t")
        case "Home": write("\u{1b}[H")
        case "End": write("\u{1b}[F")
        case "Delete": write("\u{1b}[3~")
        case "PageUp": write("\u{1b}[5~")
        case "PageDown": write("\u{1b}[6~")
        case "ShiftTab": write("\u{1b}[Z")
        case "F1": write("\u{1b}OP")
        case "F2": write("\u{1b}OQ")
        case "F3": write("\u{1b}OR")
        case "F4": write("\u{1b}OS")
        case "F5": write("\u{1b}[15~")
        case "F6": write("\u{1b}[17~")
        case "F7": write("\u{1b}[18~")
        case "F8": write("\u{1b}[19~")
        case "F9": write("\u{1b}[20~")
        case "F10": write("\u{1b}[21~")
        case "F11": write("\u{1b}[23~")
        case "F12": write("\u{1b}[24~")
        default: break
        }
    }

    /// Ctrl + letter (from KeyCapture): the control byte.
    func control(_ letter: Character) {
        guard stage == .connected, let v = letter.uppercased().first?.asciiValue, v >= 65, v <= 90 else { return }
        write(String(bytes: [v - 64], encoding: .utf8) ?? "")
    }

    /// Trackpad / mouse wheel: scroll the terminal's scrollback (the desktop's shield keeps touches).
    func scroll(dx: CGFloat, dy: CGFloat) {
        let v = displayView
        let minY = -v.adjustedContentInset.top
        let maxY = max(minY, v.contentSize.height - v.bounds.height)
        let y = max(minY, min(v.contentOffset.y + dy, maxY))
        if y != v.contentOffset.y { v.setContentOffset(CGPoint(x: v.contentOffset.x, y: y), animated: false) }
    }

    private func write(_ s: String) {
        if mode == .local {
            idesk_shell_input(s, Int32(s.utf8.count))
            return
        }
        guard let stdin else { return }
        Task { try? await stdin.write(ByteBuffer(string: s)) }
    }

    /// The window changed size: tell the remote the terminal's new columns and rows.
    func updateSize() {
        let t = displayView.getTerminal()
        if mode == .local, t.cols != lastCols || t.rows != lastRows {
            lastCols = t.cols
            lastRows = t.rows
            idesk_shell_resize(Int32(t.cols), Int32(t.rows))   // SIGWINCH: TUI apps redraw
            displayView.setNeedsDisplay(displayView.bounds)    // full repaint, not just damage
            return
        }
        guard let stdin, t.cols != lastCols || t.rows != lastRows else { return }
        lastCols = t.cols
        lastRows = t.rows
        displayView.setNeedsDisplay(displayView.bounds)
        Task { try? await stdin.changeSize(cols: t.cols, rows: t.rows, pixelWidth: 0, pixelHeight: 0) }
    }

    // MARK: Local shell (embedded iSH-ARM64)

    private func startLocal() {
        mode = .local
        // The engine is already running: reattach this window to it instead of blocking or
        // booting twice. The engine keeps feeding the original session's view, which this
        // window now shows (displayView), so the running shell and its scrollback come back.
        if let existing = LocalShell.session {
            attached = existing
            LocalShell.viewer = self
            stage = .connected
            DispatchQueue.main.async { self.updateSize() }  // SIGWINCH: redraw at this window's size
            return
        }
        feedText("\r\n\u{1B}[1mLocal mode.\u{1B}[0m Preparing Alpine Linux...\r\n")
        stage = .connecting
        Thread.detachNewThread { [weak self] in
            let rootfs = LocalShell.installRootfs { pct in
                DispatchQueue.main.async {
                    self?.feedText("\rCopying the Alpine system (first boot only)... \(pct)%   ")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let rootfs else {
                    self.fail("The bundled Alpine rootfs is unusable: \(LocalShell.lastError)")
                    return
                }
                self.bootLocal(rootfs: rootfs)
            }
        }
    }

    /// Boots the embedded kernel on a dedicated thread and wires its console into this session.
    private func bootLocal(rootfs: String) {
        feedText("\r\nBooting Alpine Linux...\r\n")
        LocalShell.session = self
        LocalShell.viewer = self
        LocalShell.output = { bytes in
            DispatchQueue.main.async { LocalShell.session?.terminalView.feed(byteArray: bytes[...]) }
        }
        idesk_shell_set_output_callback { buf, len in
            guard let buf, len > 0 else { return }
            LocalShell.output?(Array(UnsafeRawBufferPointer(start: buf, count: Int(len))))
        }
        let t = displayView.getTerminal()
        idesk_shell_resize(Int32(t.cols), Int32(t.rows))
        Thread.detachNewThread {
            let err = idesk_shell_boot(rootfs)
            DispatchQueue.main.async {
                LocalShell.session = nil
                LocalShell.output = nil
                let viewer = LocalShell.viewer
                LocalShell.viewer = nil
                viewer?.localEngineEnded(err)
            }
        }
        stage = .connected
    }

    /// R in the mode picker: a local session exists but is stuck or unwanted. Ask the guest to
    /// exit, wait for the engine to come down, then boot fresh.
    private func resetLocal() {
        mode = .local
        stage = .connecting
        feedText("\r\nResetting the local session...\r\n")
        let interrupt = "\u{3}"   // Ctrl-C: get back to the shell prompt if a program is running
        idesk_shell_input(interrupt, Int32(interrupt.utf8.count))
        let exitCmd = "exit\n"
        idesk_shell_input(exitCmd, Int32(exitCmd.utf8.count))
        awaitResetAndReboot(attempts: 40)   // 8 seconds
    }

    private func awaitResetAndReboot(attempts: Int) {
        if LocalShell.session == nil {
            startLocal()
            return
        }
        guard attempts > 0 else {
            fail("Reset failed: the engine is not responding. Close this window and try again, or restart the app.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.awaitResetAndReboot(attempts: attempts - 1)
        }
    }

    /// The kernel stopped (shell exited, or boot failed): tell the window that is showing it.
    private func localEngineEnded(_ err: Int32) {
        fail(err < 0 ? "Local shell failed to boot (error \(-err))." : "Local session ended.")
    }

    // MARK: SSH

    private func connect() {
        stage = .connecting
        feedText("Connecting to \(user)@\(host):\(port)…\r\n")
        let host = self.host, user = self.user, pass = self.pass, port = self.port
        Task { [weak self] in
            guard let self else { return }
            do {
                let settings = SSHClientSettings(
                    host: host, port: port,
                    authenticationMethod: { .passwordBased(username: user, password: pass) },
                    hostKeyValidator: .acceptAnything())
                let client = try await SSHClient.connect(to: settings)
                self.connBox.client = client
                let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: "xterm-256color",
                    terminalCharacterWidth: lastCols, terminalRowHeight: lastRows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0,
                    terminalModes: .init([:]))
                try await client.withPTY(pty) { inbound, outbound in
                    await MainActor.run {
                        self.stdin = outbound
                        self.stage = .connected
                        self.updateSize()
                    }
                    for try await out in inbound {
                        let bytes: [UInt8]
                        switch out {
                        case .stdout(let b), .stderr(let b): bytes = Array(b.readableBytesView)
                        }
                        await MainActor.run { self.terminalView.feed(byteArray: bytes[...]) }
                    }
                }
                await MainActor.run { if self.stage == .connected { self.fail("Connection closed.") } }
            } catch {
                await MainActor.run { self.fail("Connection failed: \(error.localizedDescription)") }
            }
        }
    }

    deinit {
        let client = connBox.client
        Task.detached { try? await client?.close() }
    }
}

/// State of the one local shell: the embedded kernel boots once per process, so one local
/// terminal at a time (SSH sessions are unlimited, they are just network connections).
enum LocalShell {
    /// The session that booted the engine, held strongly so the engine keeps a live screen buffer
    /// even when its window was closed; a later window reattaches to it (displayView).
    static var session: TerminalSession?
    /// The window currently showing the local shell (comes and goes as windows open and close).
    static weak var viewer: TerminalSession?
    /// Where console bytes from the kernel go.
    static var output: (([UInt8]) -> Void)?

    /// Why the last installRootfs call failed (for the on-screen error).
    static private(set) var lastError = "unknown"

    /// Where the bundled rootfs actually is. SwiftPM puts resources in a resource bundle, and
    /// xtool's packaging drops that bundle's Info.plist, which makes Bundle.resourceURL come back
    /// nil on device. Walk the real directories instead of trusting bundle metadata: the app
    /// root, then any *.bundle subdirectory (iDeskPM_iDesk.bundle and friends).
    static func bundledRootfs() -> URL? {
        let fm = FileManager.default
        var roots = [Bundle.main.bundleURL]
        if let res = Bundle.main.resourceURL, !roots.contains(res) { roots.append(res) }
        for root in roots {
            let direct = root.appendingPathComponent("alpine-rootfs")
            if fm.fileExists(atPath: direct.path) { return direct }
            if let subs = try? fm.contentsOfDirectory(atPath: root.path) {
                for sub in subs where sub.hasSuffix(".bundle") {
                    let candidate = root.appendingPathComponent(sub).appendingPathComponent("alpine-rootfs")
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
        }
        return nil
    }

    /// The fakefs rootfs must be writable (meta.db changes as the guest touches files): copy the
    /// bundled Alpine tree to Application Support on first run. Returns its path. Copies file by
    /// file and reports percent so first boot shows progress instead of looking hung.
    static func installRootfs(progress: (Int) -> Void) -> String? {
        guard let bundled = bundledRootfs() else {
            lastError = "not found under \(Bundle.main.bundleURL.path) or its resource bundles"
            return nil
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let installed = support.appendingPathComponent("alpine-rootfs")
        if fm.fileExists(atPath: installed.path) { return installed.path }
        guard let items = fm.enumerator(at: bundled, includingPropertiesForKeys: nil)?.allObjects as? [URL] else {
            lastError = "could not enumerate \(bundled.path)"
            return nil
        }
        let total = max(items.count, 1)
        do {
            try fm.createDirectory(at: installed, withIntermediateDirectories: true)
            for (i, url) in items.enumerated() {
                let rel = String(url.path.dropFirst(bundled.path.count + 1))
                let dst = installed.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                } else {
                    try fm.copyItem(at: url, to: dst)
                }
                if i % 25 == 0 { progress(i * 100 / total) }
            }
            progress(100)
            return installed.path
        } catch {
            try? fm.removeItem(at: installed)
            lastError = "copy failed: \(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - On-screen terminal key bar

/// Sticky modifiers shared by the key bar and the ordinary typing path: tap Ctrl on the bar,
/// then type c on the iPhone keyboard, and the terminal gets the control byte (0x03). One-shot:
/// a modifier releases after the next key. Alt sends the ESC prefix, like a PC's Meta key.
enum TerminalMods {
    static let changed = Notification.Name("iDeskTerminalModsChanged")
    static var ctrl = false { didSet { NotificationCenter.default.post(name: changed, object: nil) } }
    static var alt = false { didSet { NotificationCenter.default.post(name: changed, object: nil) } }
    static var shift = false { didSet { NotificationCenter.default.post(name: changed, object: nil) } }

    static func reset() { ctrl = false; alt = false; shift = false }

    /// Sends typed text to a terminal with the sticky modifiers applied.
    static func send(_ s: String, to term: TerminalSession) {
        let c = ctrl, a = alt, sh = shift
        reset()
        guard c || a || sh else { term.sendText(s); return }
        var out = ""
        for ch in s {
            if c, let v = ch.uppercased().first?.asciiValue, v >= 64, v <= 95 {
                if a { out.append("\u{1b}") }
                out.append(String(bytes: [v - 64], encoding: .utf8) ?? "")
            } else {
                if a { out.append("\u{1b}") }
                out.append(sh ? String(ch).uppercased() : String(ch))
            }
        }
        term.sendText(out)
    }
}

/// The PC-keyboard bar above the iPhone keyboard while a terminal window is focused: Esc, Tab,
/// sticky Ctrl / Alt / Shift, arrows, editing keys, and an Fn page with F1-F12 — the keys the
/// phone keyboard does not have. Each key injects the bytes the shell expects, in both Local
/// and SSH mode (they share the same session input path).
final class TerminalKeyBar: UIView {
    private let model: DesktopModel
    private var watcher: AnyCancellable?
    private var modWatcher: NSObjectProtocol?
    private var showFn = false
    private let stack = UIStackView()
    private var modButtons: [UIButton] = []
    /// Set by KeyCaptureView: whether the on-screen keyboard is up.
    var keyboardShown = false { didSet { refresh() } }
    /// Fires when the bar should appear or disappear (focus or keyboard change).
    var onVisibilityChange: () -> Void = {}
    private var wasVisible = false

    init(model: DesktopModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 46))
        backgroundColor = UIColor(white: 0.13, alpha: 1)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.frame = bounds.insetBy(dx: 8, dy: 6)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        scroll.addSubview(stack)
        addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        watcher = model.$focusedID.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        modWatcher = NotificationCenter.default.addObserver(forName: TerminalMods.changed, object: nil,
                                                            queue: .main) { [weak self] _ in self?.syncMods() }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let modWatcher { NotificationCenter.default.removeObserver(modWatcher) } }

    /// Visible only while the keyboard is up and the focused window is a terminal.
    var shouldShow: Bool { keyboardShown && model.focused?.terminal != nil }
    private func refresh() {
        let v = shouldShow
        if v != wasVisible { wasVisible = v; onVisibilityChange() }
    }

    @discardableResult
    private func addKey(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        b.backgroundColor = UIColor(white: 0.28, alpha: 1)
        b.layer.cornerRadius = 6
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        stack.addArrangedSubview(b)
        return b
    }

    private func addMod(_ title: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) {
        let b = addKey(title) { [weak self] in set(!get()); self?.syncMods() }
        b.tag = modButtons.count   // 0 = Ctrl, 1 = Alt, 2 = Shift
        modButtons.append(b)
    }

    private func syncMods() {
        let on = [TerminalMods.ctrl, TerminalMods.alt, TerminalMods.shift]
        for (i, b) in modButtons.enumerated() where i < on.count {
            b.backgroundColor = on[i] ? .systemBlue : UIColor(white: 0.28, alpha: 1)
        }
    }

    private func rebuild() {
        modButtons = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if showFn {
            addKey("\u{2039}") { [weak self] in self?.showFn = false; self?.rebuild() }
            for i in 1...12 {
                let name = "F\(i)"
                addKey(name) { [weak self] in self?.key(name) }
            }
            return
        }
        addKey("Esc") { [weak self] in self?.key("Escape") }
        addMod("Ctrl", { TerminalMods.ctrl }, { TerminalMods.ctrl = $0 })
        addMod("Alt", { TerminalMods.alt }, { TerminalMods.alt = $0 })
        addMod("Shift", { TerminalMods.shift }, { TerminalMods.shift = $0 })
        addKey("Tab") { [weak self] in self?.key("Tab") }
        addKey("\u{2190}") { [weak self] in self?.key("ArrowLeft") }
        addKey("\u{2191}") { [weak self] in self?.key("ArrowUp") }
        addKey("\u{2193}") { [weak self] in self?.key("ArrowDown") }
        addKey("\u{2192}") { [weak self] in self?.key("ArrowRight") }
        addKey("Home") { [weak self] in self?.key("Home") }
        addKey("End") { [weak self] in self?.key("End") }
        addKey("PgUp") { [weak self] in self?.key("PageUp") }
        addKey("PgDn") { [weak self] in self?.key("PageDown") }
        addKey("Del") { [weak self] in self?.key("Delete") }
        addKey("|") { [weak self] in self?.text("|") }
        addKey("`") { [weak self] in self?.text("`") }
        addKey("~") { [weak self] in self?.text("~") }
        addKey("Fn") { [weak self] in self?.showFn = true; self?.rebuild() }
        syncMods()
    }

    private func key(_ name: String) {
        if name == "Tab", TerminalMods.shift { model.terminalKey("ShiftTab") }
        else { model.terminalKey(name) }
        TerminalMods.reset()   // one-shot: a special key consumes the modifiers too
    }
    private func text(_ s: String) { model.terminalText(s) }
}

/// Hosts the terminal view inside a desktop window. Touches stay with iDesk's shield: the terminal
/// never handles them, it only draws. The container lets a reattached local session swap the old
/// session's live view in for this window's fresh one (resume), and forwards real layout resizes
/// to the session so the engine gets SIGWINCH exactly when the pixels change.
final class TerminalContainer: UIView {
    var onLayout: () -> Void = {}
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout()
    }
}

struct TerminalHost: UIViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeUIView(context: Context) -> UIView {
        let container = TerminalContainer()
        container.backgroundColor = UIColor(white: 0.08, alpha: 1)
        container.onLayout = { [weak session] in session?.updateSize() }
        embed(session.displayView, in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if container.subviews.first != session.displayView {
            container.subviews.forEach { $0.removeFromSuperview() }
            embed(session.displayView, in: container)
        }
        session.updateSize()
    }

    private func embed(_ v: TerminalView, in container: UIView) {
        v.frame = container.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(v)
    }
}

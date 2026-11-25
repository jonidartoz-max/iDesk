import UIKit
import SwiftUI
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
            idesk_shell_resize(Int32(t.cols), Int32(t.rows))
            return
        }
        guard let stdin, t.cols != lastCols || t.rows != lastRows else { return }
        lastCols = t.cols
        lastRows = t.rows
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

/// Hosts the terminal view inside a desktop window. Touches stay with iDesk's shield: the terminal
/// never handles them, it only draws.
struct TerminalHost: UIViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeUIView(context: Context) -> TerminalView { session.displayView }

    func updateUIView(_ view: TerminalView, context: Context) {
        session.updateSize()
    }
}

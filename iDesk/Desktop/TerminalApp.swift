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
    /// Where the session is: asking for the connection details, connecting, or live.
    enum Stage: Equatable {
        case askHost, askUser, askPass, connecting, connected, closed
    }
    @Published private(set) var stage: Stage = .askHost

    let terminalView: TerminalView
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
        askHost()
    }

    private enum Keys {
        static let host = "iDesk.terminal.host"
        static let user = "iDesk.terminal.user"
    }

    // MARK: Prompts

    private func banner() {
        feedText("iDesk Terminal (SSH)\r\n")
        feedText("Connect to your PC, server or WSL. Host keys are not verified (private use).\r\n\r\n")
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

    private func feedText(_ s: String) { terminalView.feed(text: s) }

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
            // A pasted multi-line text: each line runs as if typed and Enter pressed.
            write(s.replacingOccurrences(of: "\n", with: "\r"))
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
        case .connecting, .closed:
            break
        }
    }

    func keyEnter() {
        switch stage {
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
            askHost()
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
        let v = terminalView
        let minY = -v.adjustedContentInset.top
        let maxY = max(minY, v.contentSize.height - v.bounds.height)
        let y = max(minY, min(v.contentOffset.y + dy, maxY))
        if y != v.contentOffset.y { v.setContentOffset(CGPoint(x: v.contentOffset.x, y: y), animated: false) }
    }

    private func write(_ s: String) {
        guard let stdin else { return }
        Task { try? await stdin.write(ByteBuffer(string: s)) }
    }

    /// The window changed size: tell the remote the terminal's new columns and rows.
    func updateSize() {
        let t = terminalView.getTerminal()
        guard let stdin, t.cols != lastCols || t.rows != lastRows else { return }
        lastCols = t.cols
        lastRows = t.rows
        Task { try? await stdin.changeSize(cols: t.cols, rows: t.rows, pixelWidth: 0, pixelHeight: 0) }
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

/// Hosts the terminal view inside a desktop window. Touches stay with iDesk's shield: the terminal
/// never handles them, it only draws.
struct TerminalHost: UIViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeUIView(context: Context) -> TerminalView { session.terminalView }

    func updateUIView(_ view: TerminalView, context: Context) {
        session.updateSize()
    }
}

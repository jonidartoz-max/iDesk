import UIKit
import SwiftUI
import Combine

/// "Use a laptop as the display": the desktop runs on the iPhone (shown small, and touchable, like preview mode) and
/// RemoteDisplay sends it to a browser on the laptop, which also sends back its mouse and keyboard.
final class LaptopModeController: UIViewController {
    private let model = DesktopModel.shared
    private var desktopSize = RemoteDisplay.shared.desktopSize
    private var sizeWatch: AnyCancellable?
    private lazy var host = UIHostingController(rootView: DesktopView(model: model))
    private lazy var bar = UIHostingController(rootView: LaptopBar { [weak self] in self?.stop() })
    /// The rounded, lit frame the small desktop sits in.
    private let card = UIView()
    private var lastPan: CGPoint = .zero
    private var lastDrag: CGPoint = .zero
    private lazy var momentum = ScrollMomentum { [weak self] dx, dy in self?.model.scroll(dx: dx, dy: dy) }

    /// Starts laptop mode on the iPhone (only without a real display: a cable or AirPlay is better).
    static func present() {
        guard !ExternalDisplay.isConnected, var top = PhoneWindow.current?.rootViewController else { return }
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        let vc = LaptopModeController()
        vc.modalPresentationStyle = .fullScreen
        top.present(vc, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        model.screenSize = desktopSize

        addChild(bar)
        bar.view.backgroundColor = .clear
        view.addSubview(bar.view)
        bar.didMove(toParent: self)
        card.backgroundColor = UIColor(white: 0.08, alpha: 1)
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        card.layer.shadowColor = UIColor.systemBlue.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 24
        view.addSubview(card)

        host.overrideUserInterfaceStyle = .dark
        addChild(host)
        host.view.layer.anchorPoint = .zero
        host.view.bounds = CGRect(origin: .zero, size: desktopSize)
        host.view.backgroundColor = .black
        host.view.layer.masksToBounds = true
        view.addSubview(host.view)
        host.didMove(toParent: self)
        ExternalSceneDelegate.desktopView = host.view

        // Touching the small desktop works too (see PreviewController): taps click, drags drag, hold = right click.
        let shield = UIView()
        shield.tag = 7
        view.addSubview(shield)
        shield.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        // One finger scrolls what is under the pointer (naturally, with momentum): the everyday gesture.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        shield.addGestureRecognizer(pan)
        // Two fingers move the pointer and drag: windows, scrollbars, text selection.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.minimumNumberOfTouches = 2
        drag.maximumNumberOfTouches = 2
        shield.addGestureRecognizer(drag)
        // Pinch: close two fingers to minimize the window under them, open to bring it back. Two-finger
        // dragging waits a beat to make sure it is not a pinch first.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        shield.addGestureRecognizer(pinch)
        drag.require(toFail: pinch)
        // Touch and hold = right click. Short and tolerant: a finger is never perfectly still.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 24
        shield.addGestureRecognizer(hold)

        model.externalConnected()
        RemoteDisplay.shared.start()
        // The laptop's window has another shape: the desktop takes it (windows are fitted to the new size).
        sizeWatch = RemoteDisplay.shared.$desktopSize.dropFirst().removeDuplicates().sink { [weak self] size in
            guard let self else { return }
            desktopSize = size
            host.view.bounds = CGRect(origin: .zero, size: size)
            model.screenSize = size
            view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        // One compact bar on top (address + Stop); the desktop card takes everything else.
        let barHeight: CGFloat = 56
        bar.view.frame = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: barHeight)
        let area = CGRect(x: safe.minX + 12, y: safe.minY + barHeight, width: safe.width - 24,
                          height: safe.height - barHeight).insetBy(dx: 0, dy: 8)
        let s = min(area.width / desktopSize.width, area.height / desktopSize.height)
        let w = desktopSize.width * s, h = desktopSize.height * s
        let frame = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        host.view.transform = CGAffineTransform(scaleX: s, y: s)
        host.view.layer.position = frame.origin
        host.view.layer.cornerRadius = 14 / s
        card.frame = frame.insetBy(dx: -1, dy: -1)
        view.viewWithTag(7)?.frame = frame
    }

    private func stop() {
        sizeWatch = nil
        momentum.cancel()
        RemoteDisplay.shared.stop()
        if ExternalSceneDelegate.desktopView === host.view { ExternalSceneDelegate.desktopView = nil }
        // The phone's own desktop (PreviewController) stays alive underneath: hand the display role back to it.
        if let preview = PhoneWindow.current?.rootViewController as? PreviewController {
            model.externalConnected()
            preview.reclaimDesktopView()
        } else {
            model.externalDisconnected()
        }
        dismiss(animated: true)
    }

    private func point(_ g: UIGestureRecognizer) -> CGPoint { g.location(in: host.view) }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        model.cursor.position = point(g)
        model.click()
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        model.cursor.position = point(g)
        model.rightClick()
    }

    /// One finger: natural scrolling at exactly the finger's speed (the points are the small desktop's own,
    /// so content follows the finger one to one), gliding on after the lift like a scroll view.
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = point(g)
        switch g.state {
        case .began:
            momentum.cancel()
            model.cursor.position = p
        case .changed:
            model.scroll(dx: -(p.x - lastPan.x), dy: -(p.y - lastPan.y))
        default:
            let v = g.velocity(in: host.view)
            momentum.start(vx: -v.x, vy: -v.y)
        }
        lastPan = p
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        model.pinch(scale: g.scale, at: point(g), state: g.state)
    }

    /// Two fingers: the pointer itself — press, drag and drop on the desktop.
    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let p = point(g)
        switch g.state {
        case .began:
            let t = g.translation(in: host.view)
            model.cursor.position = CGPoint(x: p.x - t.x, y: p.y - t.y)
            model.mouseDown()
            model.moveCursor(dx: t.x, dy: t.y)
        case .changed:
            model.moveCursor(dx: p.x - lastDrag.x, dy: p.y - lastDrag.y)
        default:
            model.mouseUp()
        }
        lastDrag = p
    }
}

/// The compact bar on top of the iPhone in laptop mode: the address to open on the laptop, the connection
/// dot, and Stop. Everything else on the screen is the desktop card.
private struct LaptopBar: View {
    @ObservedObject var remote = RemoteDisplay.shared
    @State private var copied = false
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(remote.viewers > 0 ? Color.green : Color.orange).frame(width: 8, height: 8)
            if let failure = remote.failure {
                Text(verbatim: failure).font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let address = remote.address {
                Button {
                    UIPasteboard.general.string = address
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: address.replacingOccurrences(of: "http://", with: ""))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            } else {
                Text("Join the same Wi-Fi as the laptop.").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Button(action: stop) {
                Text("Stop").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

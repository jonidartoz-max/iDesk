import UIKit
import SwiftUI
import Combine

/// The desktop on the iPhone itself: fullscreen, in portrait or landscape, controlled by touching it directly.
/// This is how iDesk opens; the trackpad/keyboard screen and laptop mode are reachable from Settings on the desktop.
/// Tap = click, one finger = move the pointer and drag, two fingers = scroll (with momentum), hold = right click.
/// The `-iDeskPreview` launch argument still works; add `-iDeskInstall <path.ipa> [more.ipa…]` to install and open
/// apps, or `-iDeskOpen <url>` to open a web page.
final class PreviewController: UIViewController {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-iDeskPreview") }

    private let model = DesktopModel.shared
    /// The desktop's logical size: about 604 points on the short side, so window controls and text stay
    /// touch-sized on the phone (the original 786-point base made everything a third too small).
    private var desktopSize = CGSize(width: 604, height: 1208)
    private lazy var host = UIHostingController(rootView: DesktopView(model: model))
    private var lastPan: CGPoint = .zero
    private var lastScroll: CGPoint = .zero
    private lazy var momentum = ScrollMomentum { [weak self] dx, dy in self?.model.scroll(dx: dx, dy: dy) }
    private let keys = KeyCaptureView()
    private let keyboardButton = UIButton(type: .system)
    private var noticeWatch: AnyCancellable?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    /// The desktop is fullscreen: swiping at the edges scrolls and drags windows first, not iOS's gestures.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        model.screenSize = desktopSize

        host.overrideUserInterfaceStyle = .dark
        addChild(host)
        host.view.layer.anchorPoint = .zero
        host.view.bounds = CGRect(origin: .zero, size: desktopSize)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        ExternalSceneDelegate.desktopView = host.view     // what screenshots capture, as on a real display

        // A transparent shield over the desktop: real touches stop here and go through DesktopModel,
        // exactly like with an external display. The desktop itself cannot have interaction disabled: UIKit ignores
        // actions (row selection, buttons) in a guest app when any superview has interaction disabled.
        let shield = UIView(frame: view.bounds)
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(shield)
        shield.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        shield.addGestureRecognizer(pan)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        shield.addGestureRecognizer(scroll)
        // Touch and hold = right click (context menus). Short and tolerant: a finger is never perfectly still.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 24
        shield.addGestureRecognizer(hold)

        // Typing: a hidden text view mirrors the iPhone's keyboard onto the desktop; the small floating
        // button summons and dismisses it.
        keys.onInsert = { [weak self] text in self?.model.typeText(text) }
        keys.onDelete = { [weak self] in self?.model.backspace() }
        keys.onEnter = { [weak self] in self?.model.pressEnter() }
        keys.showsKeyboard = true
        view.addSubview(keys)
        keyboardButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        keyboardButton.tintColor = .white
        keyboardButton.backgroundColor = UIColor(white: 0.15, alpha: 0.6)
        keyboardButton.layer.cornerRadius = 22
        keyboardButton.alpha = 0.75
        keyboardButton.addTarget(self, action: #selector(toggleKeyboard), for: .touchUpInside)
        view.addSubview(keyboardButton)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

        // Errors and install results (they used to appear on the controller screen).
        noticeWatch = model.$notice.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] text in
            self?.showNotice(text)
        }

        model.externalConnected()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        // Follow the phone's shape (portrait or landscape), the long side at most 2.5× the short one.
        let r = min(2.5, max(1.3, max(safe.width, safe.height) / min(safe.width, safe.height)))
        let base: CGFloat = 604
        let size = safe.height >= safe.width
            ? CGSize(width: base, height: (base * r).rounded())
            : CGSize(width: (base * r).rounded(), height: base)
        if size != desktopSize {
            desktopSize = size
            host.view.bounds = CGRect(origin: .zero, size: size)
            model.screenSize = size
        }
        let s = min(safe.width / size.width, safe.height / size.height)
        host.view.transform = CGAffineTransform(scaleX: s, y: s)
        host.view.layer.position = safe.origin
        keyboardButton.frame = CGRect(x: safe.maxX - 58, y: safe.maxY - 100, width: 44, height: 44)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-iDeskOpen"), i + 1 < args.count {
            model.openWindow(args[i + 1])
        }
        // Every path after "-iDeskInstall" up to the next option; each app that installs is opened.
        guard let i = args.firstIndex(of: "-iDeskInstall") else { return }
        let ipas = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        GuestStore.shared.install(ipas: ipas) { [model] results in
            NSLog("[iDesk] %@", GuestStore.summary(of: results))
            let apps = results.compactMap { try? $0.result.get() }
            if apps.isEmpty { model.notice = GuestStore.summary(of: results) }
            apps.forEach(model.openApp)
            if let notice = model.notice { NSLog("[iDesk] %@", notice) }
        }
    }

    /// Screenshots and the streamed picture capture this desktop again after laptop mode closed.
    func reclaimDesktopView() {
        ExternalSceneDelegate.desktopView = host.view
    }

    private func desktopPoint(_ g: UIGestureRecognizer) -> CGPoint { g.location(in: host.view) }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        model.cursor.position = desktopPoint(g)
        model.click()
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        model.cursor.position = desktopPoint(g)
        model.rightClick()
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = desktopPoint(g)
        switch g.state {
        case .began:
            let t = g.translation(in: host.view)
            model.cursor.position = CGPoint(x: p.x - t.x, y: p.y - t.y)
            model.mouseDown()
            model.moveCursor(dx: t.x, dy: t.y)
        case .changed:
            model.moveCursor(dx: p.x - lastPan.x, dy: p.y - lastPan.y)
        default:
            model.mouseUp()
        }
        lastPan = p
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let p = desktopPoint(g)
        switch g.state {
        case .began:
            momentum.cancel()
            model.cursor.position = p
        case .changed:
            model.scroll(dx: -(p.x - lastScroll.x), dy: -(p.y - lastScroll.y))
        default:
            // Natural scrolling glides on after the fingers lift, like everywhere else on the iPhone.
            let v = g.velocity(in: host.view)
            momentum.start(vx: -v.x, vy: -v.y)
        }
        lastScroll = p
    }

    // MARK: Keyboard

    @objc private func toggleKeyboard() {
        if keys.isFirstResponder { keys.resignFirstResponder() } else { keys.becomeFirstResponder() }
    }

    @objc private func keyboardChanged(_ note: Notification) {
        let shown = note.name == UIResponder.keyboardWillShowNotification
        keyboardButton.tintColor = shown ? UIColor.systemGreen : .white
    }

    // MARK: Notices

    private func showNotice(_ text: String) {
        let alert = UIAlertController(title: "iDesk", message: text, preferredStyle: .alert)
        if let url = model.crashReportURL {
            alert.addAction(UIAlertAction(title: String(localized: "Send report"), style: .default) { [weak self] _ in
                UIApplication.shared.open(url)
                self?.model.crashReport = nil
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Copy error"), style: .default) { _ in
            UIPasteboard.general.string = text
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.model.notice = nil
        })
        var top = self
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        top.present(alert, animated: true)
    }
}

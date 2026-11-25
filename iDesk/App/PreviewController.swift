import UIKit
import SwiftUI
import Combine

/// The desktop on the iPhone itself: fullscreen, in portrait or landscape, controlled by touching it directly.
/// This is how iDesk opens; the trackpad/keyboard screen and laptop mode are reachable from Settings on the desktop.
/// Tap = click (tolerant of a shaky finger), one finger = drag what is grabbable and scroll everywhere
/// else (with momentum), two fingers = scroll, hold = right click, pinch out on a window = widen it to
/// fill the desktop, pinch in = back to its size before.
/// The `-iDeskPreview` launch argument still works; add `-iDeskInstall <path.ipa> [more.ipa…]` to install and open
/// apps, or `-iDeskOpen <url>` to open a web page.
final class PreviewController: UIViewController {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-iDeskPreview") }

    private let model = DesktopModel.shared
    /// The desktop's logical size: 560 points on the short side, so window controls and text stay
    /// touch-sized on the phone (the original 786-point base made everything a third too small).
    /// 560 matches the device-proven v5 build: ~20% bigger targets, exactly what he asked for.
    private var desktopSize = CGSize(width: 560, height: 1208)
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
        // A tap survives a shaky finger (24 pt, the device-proven v5 tolerance) instead of dying on any wiggle.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        if tap.responds(to: Selector(("setAllowableMovement:"))) {
            tap.setValue(24.0, forKey: "allowableMovement")
        }
        shield.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        shield.addGestureRecognizer(pan)
        // Safari edge swipes: from the left edge = back, from the right edge = forward
        // in the browser window under the finger.
        let edgeL = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        edgeL.edges = .left
        let edgeR = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        edgeR.edges = .right
        shield.addGestureRecognizer(edgeL)
        shield.addGestureRecognizer(edgeR)
        pan.require(toFail: edgeL)
        pan.require(toFail: edgeR)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        shield.addGestureRecognizer(scroll)
        // Pinch on a window: spreading widens it to fill the desktop, closing brings its size back.
        // Nothing waits on the pinch, so one- and two-finger scrolling stays instant.
        shield.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
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
        // Auto keyboard: a text field tapped in any window opens the keyboard, leaving it closes it.
        NotificationCenter.default.addObserver(self, selector: #selector(typingFocusChanged(_:)),
                                               name: .iDeskTypingFocus, object: nil)

        // Errors and install results (they used to appear on the controller screen).
        noticeWatch = model.$notice.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] text in
            self?.showNotice(text)
        }

        model.externalConnected()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDesktop()
    }

    private func layoutDesktop() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        // Follow the phone's shape (portrait or landscape), the long side at most 2.5× the short one.
        let r = min(2.5, max(1.3, max(safe.width, safe.height) / min(safe.width, safe.height)))
        let base: CGFloat = 560       // matches the v5 device-proven UI scale (P4)
        let size = safe.height >= safe.width
            ? CGSize(width: base, height: (base * r).rounded())
            : CGSize(width: (base * r).rounded(), height: base)
        if size != desktopSize {
            desktopSize = size
            host.view.bounds = CGRect(origin: .zero, size: size)
            model.screenSize = size
        }
        // The keyboard takes the bottom: the desktop scales into what is left above it, like a native app.
        let free = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(80, safe.height - keyboardHeight))
        let s = min(free.width / size.width, free.height / size.height)
        host.view.transform = CGAffineTransform(scaleX: s, y: s)
        host.view.layer.position = free.origin
        keyboardButton.frame = CGRect(x: free.maxX - 58, y: free.maxY - 100, width: 44, height: 44)
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

    /// One finger: drags what is actually grabbable (title bar, icon, widget, sticky, resize edge,
    /// guest touch); anywhere else it scrolls the content under the finger, following the finger and
    /// gliding on after the lift — the device-proven v5/v6 feel, now with momentum.
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = desktopPoint(g)
        switch g.state {
        case .began:
            let t = g.translation(in: host.view)
            model.cursor.position = CGPoint(x: p.x - t.x, y: p.y - t.y)
            model.mouseDown()
            model.moveCursor(dx: t.x, dy: t.y)
            panScrolled = false
            keyboardDragDismiss = keyboardHeight > 0 && p.y > host.view.bounds.maxY - 120
        case .changed:
            if keyboardDragDismiss {
                let t = g.translation(in: host.view)
                if t.y > 60, t.y > abs(t.x) {
                    keys.resignFirstResponder()
                    DesktopModel.hapticTap()
                    keyboardDragDismiss = false
                }
            }
            if model.touchScrollsFreely {
                if !panScrolled { panScrolled = true; momentum.cancel() }
                model.scroll(dx: -(p.x - lastPan.x), dy: -(p.y - lastPan.y))
            } else {
                model.moveCursor(dx: p.x - lastPan.x, dy: p.y - lastPan.y)
            }
        default:
            if panScrolled {
                let v = g.velocity(in: host.view)
                momentum.start(vx: -v.x, vy: -v.y)
                panScrolled = false
            }
            model.mouseUp()
            keyboardDragDismiss = false
        }
        lastPan = p
    }

    private var panScrolled = false
    private var edgeStart: CGPoint = .zero
    /// Set on touch-down while the keyboard is open and the finger starts just above it:
    /// a downward drag from there dismisses the keyboard, like swiping it away.
    private var keyboardDragDismiss = false

    @objc private func edgeSwiped(_ g: UIScreenEdgePanGestureRecognizer) {
        switch g.state {
        case .began:
            edgeStart = desktopPoint(g)
        case .ended:
            let t = g.translation(in: host.view)
            guard abs(t.x) > 48, abs(t.x) > abs(t.y) else { return }
            guard let w = model.topWindow(at: edgeStart), let web = w.webView else { return }
            if g.edges == .left, web.canGoBack { web.goBack(); DesktopModel.hapticTap() }
            if g.edges == .right, web.canGoForward { web.goForward(); DesktopModel.hapticTap() }
        default: break
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        model.pinchWiden(scale: g.scale, at: desktopPoint(g), state: g.state)
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        // A pinch resize in progress owns the two fingers.
        guard !model.isWidenActive else { return }
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

    private var keyboardHeight: CGFloat = 0

    @objc private func toggleKeyboard() {
        if keys.isFirstResponder { keys.resignFirstResponder() } else { keys.becomeFirstResponder() }
    }

    @objc private func typingFocusChanged(_ note: Notification) {
        let focus = (note.object as? Bool) ?? false
        if focus, !keys.isFirstResponder { keys.becomeFirstResponder() }
        if !focus, keys.isFirstResponder { keys.resignFirstResponder() }
    }

    /// Native-iOS keyboard feel: the desktop resizes to sit above the keyboard, animated with the
    /// keyboard's own duration and curve, and the keyboard button rides on top of it.
    @objc private func keyboardChanged(_ note: Notification) {
        let shown = note.name == UIResponder.keyboardWillShowNotification
        keyboardButton.tintColor = shown ? UIColor.systemGreen : .white
        let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        keyboardHeight = shown ? max(0, view.convert(end, from: nil).intersection(view.bounds).height) : 0
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            self.layoutDesktop()
        }
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
        var top: UIViewController = self
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        top.present(alert, animated: true)
    }
}

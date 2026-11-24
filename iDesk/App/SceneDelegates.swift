import UIKit
import SwiftUI
import Combine

/// iPhone screen: the desktop itself, fullscreen (PreviewController). The trackpad + keyboard screen
/// (ControllerView) is still there for an external display: Settings on the desktop → iPhone.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = PhoneWindow(windowScene: windowScene)
        window.rootViewController = PreviewController()
        window.makeKeyAndVisible()
        PhoneWindow.current = window
        window.claimKeyboard()
        self.window = window

        // DeX-style: when a display connects, the iPhone becomes the trackpad + keyboard by itself
        // (Settings → External display can turn this off); unplugging returns it to the desktop.
        displayObserver = DesktopModel.shared.$isExternalConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak window] connected in
                guard let window else { return }
                let auto = UserDefaults.standard.object(forKey: PhoneSceneDelegate.autoTrackpadKey) as? Bool ?? true
                if connected, auto {
                    PhoneHostingController.setLandscape(true)
                    window.rootViewController = PhoneHostingController(rootView: ControllerView(model: DesktopModel.shared))
                } else {
                    PhoneHostingController.setLandscape(false)
                    window.rootViewController = PreviewController()
                }
            }
    }

    static let autoTrackpadKey = "autoTrackpadOnDisplay"
    private var displayObserver: AnyCancellable?

    func sceneDidBecomeActive(_ scene: UIScene) {
        PhoneWindow.current?.claimKeyboard()
        GuestRuntime.forwardSceneEvent(#selector(UISceneDelegate.sceneDidBecomeActive(_:)), scene: scene)
    }

    // The guest app has no scene of its own: forward the iPhone scene's lifecycle events to it.
    func sceneWillResignActive(_ scene: UIScene) {
        GuestRuntime.forwardSceneEvent(#selector(UISceneDelegate.sceneWillResignActive(_:)), scene: scene)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        GuestRuntime.forwardSceneEvent(#selector(UISceneDelegate.sceneDidEnterBackground(_:)), scene: scene)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        GuestRuntime.forwardSceneEvent(#selector(UISceneDelegate.sceneWillEnterForeground(_:)), scene: scene)
    }

    /// "Open in iDesk" from Files / a signing app: install the shared IPAs.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        let ipas = URLContexts.map(\.url).filter { $0.pathExtension.lowercased() == "ipa" }
        GuestStore.shared.install(ipas: ipas) { results in
            var next: String?
            #if !targetEnvironment(simulator)
            if !GuestStore.canLoadOutsideBundle { next = LaunchDiagnostics.installTip }
            #endif
            DesktopModel.shared.notice = GuestStore.summary(of: results, next: next)
        }
    }
}

/// Shows the trackpad + keyboard screen from the desktop (Settings → iPhone). It closes with its own
/// back button, returning to the desktop.
enum PhoneController {
    static func present() {
        guard var top = PhoneWindow.current?.rootViewController else { return }
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        guard !(top is PhoneHostingController) else { return }
        let vc = PhoneHostingController(rootView: ControllerView(model: .shared))
        vc.modalPresentationStyle = .fullScreen
        top.present(vc, animated: true)
    }
}

/// Controller screen on the iPhone: follows device rotation; mouse mode is always landscape.
final class PhoneHostingController: UIHostingController<ControllerView> {
    private static var landscapeOnly = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        Self.landscapeOnly ? .landscape : UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// Three-finger swipes are trackpad gestures here, not iOS's undo / redo / copy gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    static func setLandscape(_ on: Bool) {
        landscapeOnly = on
        guard let window = PhoneWindow.current, let scene = window.windowScene else { return }
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        // Entering mouse mode: rotate to landscape now. Leaving: back to portrait, unless the iPhone is held sideways.
        // (Only allowing portrait again is not enough: with rotation lock on, iOS would keep the screen landscape.)
        if on, !scene.interfaceOrientation.isLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        } else if !on, scene.interfaceOrientation.isLandscape, !UIDevice.current.orientation.isLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }
}

/// External display (HDMI/USB-C): shows the desktop. This scene receives no touches,
/// so all input goes through DesktopModel (self-drawn pointer + own hit testing).
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// The desktop view on the external display, mirrored on the iPhone in mouse mode.
    static weak var desktopView: UIView?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplay.connected(windowScene.screen)
        let model = DesktopModel.shared
        model.screenSize = windowScene.coordinateSpace.bounds.size

        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .dark          // menus and panels match iDesk's dark windows
        let host = UIHostingController(rootView: DesktopView(model: model))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        Self.desktopView = host.view
        self.window = window
        // A new resolution (automatic at connection, or from Settings): the desktop takes the screen's new size.
        // The scene does not resize its window by itself when the mode changes after the window exists.
        modeObserver = NotificationCenter.default.addObserver(forName: UIScreen.modeDidChangeNotification,
                                                              object: windowScene.screen, queue: .main) { [weak self] _ in
            self?.fitToScreen()
        }
        DispatchQueue.main.async { [weak self] in self?.fitToScreen() }

        model.externalConnected()
    }

    private var modeObserver: NSObjectProtocol?

    private func fitToScreen() {
        guard let window, let screen = window.windowScene?.screen else { return }
        let size = screen.bounds.size
        guard size.width > 0, window.frame.size != size else { return }
        window.frame = CGRect(origin: .zero, size: size)
        DesktopModel.shared.screenSize = size
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
        modeObserver = nil
        DesktopModel.shared.externalDisconnected()
        ExternalDisplay.disconnected()
        window = nil
    }
}

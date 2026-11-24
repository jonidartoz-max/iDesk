import UIKit

/// Gliding after a touch scroll ends, like a UIScrollView: the flick's velocity decays smoothly and each frame
/// scrolls a little less, instead of the content freezing the moment the finger lifts.
/// One instance per gesture path; a new touch cancels the glide, as on iOS.
final class ScrollMomentum: NSObject {
    /// Called on the main thread with the scroll delta for one frame, in the same points the velocity was given in.
    private let apply: (CGFloat, CGFloat) -> Void
    private var link: CADisplayLink?
    private var vx: CGFloat = 0, vy: CGFloat = 0
    private var last: CFTimeInterval = 0

    init(apply: @escaping (CGFloat, CGFloat) -> Void) {
        self.apply = apply
    }

    deinit { link?.invalidate() }

    func cancel() {
        link?.invalidate()
        link = nil
    }

    /// Starts the glide with the flick's velocity in points per second.
    func start(vx: CGFloat, vy: CGFloat) {
        cancel()
        guard hypot(vx, vy) > 60 else { return }      // a slow lift is a stop, not a glide
        self.vx = vx
        self.vy = vy
        last = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - last)
        last = now
        // The same deceleration as a scroll view: about 0.94 per frame at 60 fps.
        let decay = CGFloat(exp(-3.4 * dt))
        vx *= decay
        vy *= decay
        guard hypot(vx, vy) > 12 else { cancel(); return }
        apply(vx * CGFloat(dt), vy * CGFloat(dt))
    }
}

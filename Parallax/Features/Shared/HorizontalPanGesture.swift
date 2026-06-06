import SwiftUI
#if !os(tvOS)
import UIKit

/// A horizontal-only pan bridged into SwiftUI via `UIGestureRecognizerRepresentable` (iOS 18+).
///
/// It begins **only** when the pan is horizontally dominant, so a vertical drag never starts it
/// and falls through to an enclosing `ScrollView` untouched. This sidesteps the iOS 18+ conflict
/// where a SwiftUI `DragGesture` and a parent `ScrollView` can't both work: `.gesture` lets the
/// drag cancel scrolling, and `.simultaneousGesture` restores scrolling but makes the content
/// "dance" (both fire at once). UIKit's recognizer arbitration — gated by `shouldBegin` — gives
/// the clean orthogonal split a horizontal pager inside a vertical scroller needs.
///
/// `onChanged`/`onEnded` report the recognizer's cumulative translation and end velocity (points,
/// in the gesture view's space) so callers can drive paging exactly as a `DragGesture` would.
struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var onChanged: (_ translationX: CGFloat) -> Void
    var onEnded: (_ translationX: CGFloat, _ velocityX: CGFloat) -> Void
    /// When false the recognizer is disabled so it never begins — and so never holds off the
    /// enclosing ScrollView. Use it to switch the pager off (e.g. a single-item carousel).
    var isEnabled: Bool = true

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translationX = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChanged(translationX)
        case .ended, .cancelled, .failed:
            onEnded(translationX, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Begin only for horizontal-dominant pans; a vertical one returns false here, which
        /// transitions this recognizer to `.failed` and frees the gesture for the ScrollView.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// Make the enclosing ScrollView's pan wait for this one to fail, rather than run
        /// alongside it. A directional lock, not simultaneous recognition: a horizontal drag
        /// begins this pan (which never fails) so the ScrollView stays put; a vertical drag
        /// fails this pan (via `shouldBegin`) so only the ScrollView scrolls. Neither axis can
        /// drive both at once, and the winner is locked in for the whole gesture.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }
    }
}
#endif

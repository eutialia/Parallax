#if os(tvOS)
import SwiftUI
import UIKit

/// A read-only, focusable, scrollable text region for tvOS.
///
/// SwiftUI `Text` is never focusable, so a long block of text inside a tvOS modal/card has no
/// focus target and the Siri Remote can't scroll it. `UITextView` is the native scrollable-text
/// control (App Store descriptions, Settings legal text), but getting it focusable + scrollable
/// inside a SwiftUI representable needs several non-obvious settings (all confirmed on Apple's
/// developer forums):
///
/// - `isSelectable = true` is what flips `canBecomeFocused` to true; we also force it in the
///   subclass because the built-in path is unreliable inside a representable.
/// - The Siri Remote reports **indirect** touches — the pan recognizer ignores them by default, so
///   without `allowedTouchTypes = [.indirect]` the view focuses but never scrolls.
/// - It must be HEIGHT-BOUNDED (via `sizeThatFits`) so its content overflows the frame; otherwise
///   it grows to fit all the text and has nothing to scroll.
/// - `UITextView` draws no focus appearance on tvOS, so the subclass adds a focus ring.
struct FocusableScrollText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .callout

    func makeUIView(context: Context) -> FocusableTextView {
        let view = FocusableTextView()
        view.isSelectable = true
        view.isUserInteractionEnabled = true
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = true
        view.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.backgroundColor = .clear
        view.layer.cornerRadius = Radius.tile
        view.textContainerInset = UIEdgeInsets(top: Space.s8, left: Space.s8, bottom: Space.s8, right: Space.s8)
        view.textContainer.lineFragmentPadding = 0
        view.textColor = UIColor(Color.label)
        view.font = UIFont.preferredFont(forTextStyle: textStyle)
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: FocusableTextView, context: Context) {
        if view.text != text {
            view.text = text
            view.setContentOffset(.zero, animated: false)
        }
    }

    /// Take the proposed (bounded) size, not the content's intrinsic height — otherwise the text
    /// view grows to fit every line, never overflows its frame, and so has nothing to scroll.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FocusableTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite,
              let height = proposal.height, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// `UITextView` exposes no focus appearance on tvOS, and its built-in `canBecomeFocused` is
/// unreliable inside a SwiftUI representable — so force focusability and supply a focus look.
/// The look is a soft theme-adaptive fill (the app's `selectionFill` token), NOT a hard white
/// border — a focused reading region should read as a gently lit panel, not an outlined box, and
/// must adapt to light mode.
final class FocusableTextView: UITextView {
    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isNowFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isNowFocused ? UIColor(Color.selectionFill) : .clear
        }, completion: nil)
    }
}
#endif

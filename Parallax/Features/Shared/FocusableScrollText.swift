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
/// - No `isEditable = false` guard is needed (or even possible): `UITextView.isEditable` is
///   `API_UNAVAILABLE(tvos)` — tvOS text views are never editable, so Select can only pan here.
///
/// `textStyle` / `design` / `textColor` are the styling knobs — they pick the Dynamic-Type ramp the
/// text scales on, its typeface design, and its ink token, so a host can match its own type scale
/// without reaching into the view.
struct FocusableScrollText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .callout
    var design: UIFontDescriptor.SystemDesign = .default
    var textColor: Color = .label

    private var resolvedFont: UIFont {
        let baseDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
        let descriptor = baseDescriptor.withDesign(design) ?? baseDescriptor
        return UIFont(descriptor: descriptor, size: 0)
    }

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
        view.textColor = UIColor(textColor)
        view.appliedTextColor = textColor
        view.font = resolvedFont
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    /// Every write here is guarded: assigning `text`, `font`, or `textColor` re-applies attributes
    /// across the whole string and invalidates layout, and hosts re-run `updateUIView` on unrelated
    /// state changes. `UIFont` compares by descriptor, so it can be diffed directly; `UIColor(Color)`
    /// wraps a dynamic provider that never compares equal, so the `Color` token is diffed instead —
    /// and the text is diffed against a stored copy rather than `view.text`, whose getter
    /// re-materializes the whole string out of `textStorage` before the O(n) compare even starts
    /// (this view's real payload is a 35KB licence). Comparing the two `String`s hits the identity
    /// fast path when nothing changed, which is the common case.
    func updateUIView(_ view: FocusableTextView, context: Context) {
        if view.appliedText != text {
            view.appliedText = text
            view.text = text
            // Strictly inside the text-change branch: a re-render that only restyles must not throw
            // the reader back to the top of what they were reading.
            view.setContentOffset(.zero, animated: false)
        }
        let font = resolvedFont
        if view.font != font { view.font = font }
        if view.appliedTextColor != textColor {
            view.appliedTextColor = textColor
            view.textColor = UIColor(textColor)
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
    /// The `Color` token behind the current `textColor`, so `updateUIView` can skip a redundant
    /// re-style; the resolved `UIColor` itself is a dynamic provider and never compares equal.
    var appliedTextColor: Color?

    /// The string last handed to `text`, so `updateUIView` can diff without going through
    /// `UITextView.text` — that getter rebuilds the whole string from `textStorage` on every read,
    /// which is real work on every unrelated re-render for a body this long.
    var appliedText: String?

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

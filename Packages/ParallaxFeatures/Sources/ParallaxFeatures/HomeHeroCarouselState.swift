import Observation

/// The Home carousel's page state, hoisted OUT of the carousel view because the hero's two halves
/// no longer live together: on iPhone/iPad the artwork is a fixed `heroBackdrop` behind the scroll
/// view while the foreground rides the scroll content, so a `@State` inside either half would be
/// invisible to the other. `HomeView` owns one of these and feeds both.
///
/// `@Observable` also keeps the insulation the old `@State` had: the continuous `position` is read
/// only by the artwork, so a crossfade tick re-renders the picture without touching the foreground
/// column, the page dots, or `HomeView`'s body.
///
/// Every mutation is plain; the carousel view wraps each one in its own animation curve.
@Observable
@MainActor
public final class HomeHeroCarouselState {
    /// Continuous artwork crossfade driver — integers are settled pages, fractions are mid-fade.
    public private(set) var position: Double = 0
    /// The settled page the foreground + dots show. Deliberately separate from `position`: the
    /// artwork crossfades continuously while the text swaps only on settle.
    public private(set) var displayedPage = 0
    /// Drives the foreground's hide-while-dragging transition.
    public private(set) var isDragging = false
    private var gestureStart: Double?

    public init() {}

    /// A changed entry SET snaps back to the first page. Compared on ids by the caller, so a
    /// favorite toggle doesn't reset the carousel.
    public func reset() {
        position = 0
        displayedPage = 0
        gestureStart = nil
        isDragging = false
    }

    /// Hides the foreground the moment a drag begins — any travel, not distance-based. It stays
    /// hidden until `showPage(_:)` brings the settled page back.
    public func beginDragging() {
        isDragging = true
    }

    public func drag(translationX: Double, width: Double) {
        let start = gestureStart ?? position
        gestureStart = start
        position = clampedPage(start - translationX / width, around: start)
    }

    /// The page a released drag settles on. Projects with velocity so a flick commits
    /// (UIScrollView-style); one page per gesture.
    public func endDrag(translationX: Double, velocityX: Double, width: Double) -> Int {
        let start = gestureStart ?? position
        gestureStart = nil
        let projectedX = translationX + velocityX * 0.3
        return Int(clampedPage(start - projectedX / width, around: start).rounded())
    }

    /// Moves the artwork onto `target`.
    public func settleArtwork(on target: Int) {
        position = Double(target)
    }

    /// Shows the foreground for `target` — re-inserting it after a drag, or swapping its page on
    /// auto-advance.
    public func showPage(_ target: Int) {
        isDragging = false
        displayedPage = target
    }

    /// One drag or flick moves at most one page: clamp the target to ±1 around where it began.
    private func clampedPage(_ raw: Double, around start: Double) -> Double {
        min(start + 1, max(start - 1, raw))
    }
}

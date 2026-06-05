import SwiftUI
import ParallaxJellyfin

/// Recently-added hero — an Apple-TV-style crossfade carousel.
///
/// The artwork crossfades on a continuous `position` (integers = settled pages). The
/// foreground's behaviour mirrors the Apple TV app — stateful, not distance-based, and it
/// leans on SwiftUI's own transitions rather than a hand-rolled crossfade:
///  • the moment a drag *begins* (any travel) the foreground is removed → it fades out;
///    releasing re-inserts the settled page → it fades back in. A binary hide-while-dragging.
///  • auto-advance keeps it shown but changes its `.id`, so the page change is a crossfade
///    (incoming over outgoing) with no hide.
///
/// Infinite both ways via modular indexing; native dots + pill in `HeroPageIndicator`.
struct HomeHeroCarousel: View {
    let items: [Item]
    let session: Session
    let viewModel: HomeViewModel
    /// Pull-down overscroll (pt, ≥ 0) supplied by the Home `ScrollView`'s geometry. Drives
    /// the stretchy zoom; 0 at rest or while scrolling up.
    var overscroll: CGFloat = 0

    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position: Double = 0     // continuous artwork crossfade driver
    @State private var displayedPage = 0        // settled page the foreground + dots show
    @State private var gestureStart: Double?
    @State private var isDragging = false

    private var regularWidth: Bool { hSize == .regular }
    private var heroHeight: CGFloat { HeroMetrics.height(regularWidth: regularWidth) }
    private var count: Int { items.count }

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .frame(height: heroHeight)
        // Compare ids (not items) so a favorite toggle doesn't reset the page; only a
        // changed item set snaps back to the first page.
        .onChange(of: items.map(\.id)) {
            position = 0; displayedPage = 0; gestureStart = nil; isDragging = false
        }
    }

    private func content(width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            CrossfadeArtwork(position: position, items: items, session: session, regularWidth: regularWidth)
                // Stretchy hero: a pull-down zooms the artwork up from its bottom edge to
                // fill the rubber-band gap instead of exposing the app background. Only the
                // artwork scales — the title/actions stay put. `scaleEffect` is a render
                // transform, so it can't feed the geometry it's driven by back into layout.
                .scaleEffect(1 + overscroll / heroHeight, anchor: .bottom)

            // Hidden while dragging (removed → fades out); on a settled page change its `.id`
            // flips and SwiftUI crossfades the new page over the old. No manual opacity state.
            if !isDragging {
                foregroundLayer(page: displayedPage)
                    .id(displayedPage)
                    .transition(.opacity)
            }

            HeroPageIndicator(
                numberOfPages: count,
                currentPage: ((displayedPage % count) + count) % count,
                autoAdvanceInterval: 6,
                isPaused: isDragging,
                reduceMotion: reduceMotion,
                onAdvance: { commit(to: displayedPage + 1) }
            )
            .frame(maxWidth: .infinity)
            .padding(.bottom, Space.s12)
        }
        .contentShape(Rectangle())
        // A horizontal-only UIKit pan: vertical swipes fall through to the Home ScrollView,
        // taps fall through to the Play/Favorite buttons. (A SwiftUI DragGesture can't do
        // both inside a ScrollView on iOS 18+.) No-op for a lone item.
        .gesture(
            HorizontalPanGesture(
                onChanged: { panChanged(translationX: $0, width: width) },
                onEnded: { panEnded(translationX: $0, velocityX: $1, width: width) },
                isEnabled: count > 1
            )
        )
    }

    private func foregroundLayer(page: Int) -> some View {
        let pageItem = items[wrapping: page]
        return HeroForeground(
            item: pageItem,
            session: session,
            regularWidth: regularWidth,
            resumeEpisode: viewModel.resumeEpisode(for: pageItem),
            isFavorite: pageItem.userData.isFavorite,
            onPlay: { playback.play(playTargetID(for: pageItem), in: session) },
            onToggleFavorite: { Task { await viewModel.toggleFavorite(for: pageItem.id) } }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .safeAreaPadding(.horizontal, regularWidth ? Space.s40 : Space.s22)
        .padding(.bottom, Space.s30)
    }

    private func panChanged(translationX: CGFloat, width: CGFloat) {
        let start = gestureStart ?? position
        gestureStart = start
        // Hide the foreground the moment the drag begins — any travel, not distance-based.
        // It stays hidden until release fades the page back in.
        if !isDragging { withAnimation(.easeOut(duration: 0.15)) { isDragging = true } }
        position = clampedPage(start - Double(translationX) / Double(width), around: start)
    }

    private func panEnded(translationX: CGFloat, velocityX: CGFloat, width: CGFloat) {
        let start = gestureStart ?? position
        gestureStart = nil
        // Project with velocity so a flick commits (UIScrollView-style); one page per gesture.
        let projectedX = translationX + velocityX * 0.3
        commit(to: Int(clampedPage(start - Double(projectedX) / Double(width), around: start).rounded()))
    }

    /// One drag or flick moves at most one page: clamp the target to ±1 around where it began.
    private func clampedPage(_ raw: Double, around start: Double) -> Double {
        min(start + 1, max(start - 1, raw))
    }

    /// Settle on `target`: spring the artwork there, and show the foreground for that page —
    /// re-inserting it after a drag (fade in) or crossfading its `.id` on auto-advance.
    private func commit(to target: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { position = Double(target) }
        withAnimation(.easeInOut(duration: 0.22)) {
            isDragging = false
            displayedPage = target
        }
    }

    private func playTargetID(for item: Item) -> ItemID {
        if case .series = item, let episode = viewModel.resumeEpisode(for: item) { return episode.id }
        return item.id
    }
}

/// Just the artwork crossfade. `Animatable` on `position` is the crux: during a
/// `withAnimation` `position` change, SwiftUI interpolates `animatableData` and re-evaluates
/// `body` at each step, so the two images crossfade continuously rather than cutting between
/// the start and end states. Carries `backgroundExtensionEffect`, so it paints the bleed too.
private struct CrossfadeArtwork: View, Animatable {
    var position: Double
    let items: [Item]
    let session: Session
    let regularWidth: Bool

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let lower = Int(floor(position))
        let frac = position - Double(lower)
        return ZStack {
            HeroArtwork(item: items[wrapping: lower], session: session)
            HeroArtwork(item: items[wrapping: lower + 1], session: session).opacity(frac)
        }
        .backgroundExtensionEffect(isEnabled: regularWidth)
    }
}

private extension Array {
    /// Index wrapped into bounds for the infinite carousel. Caller guarantees a non-empty array.
    subscript(wrapping index: Int) -> Element { self[((index % count) + count) % count] }
}

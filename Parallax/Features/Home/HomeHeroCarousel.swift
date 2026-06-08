import SwiftUI
import ParallaxJellyfin

/// Home hero — an Apple-TV-style crossfade carousel.
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
    let entries: [HomeHeroFeedEntry]
    let session: Session
    let viewModel: HomeViewModel
    /// Pull-down overscroll (pt, ≥ 0) supplied by the Home `ScrollView`'s geometry. Drives
    /// the stretchy zoom; 0 at rest or while scrolling up.
    var overscroll: CGFloat = 0

    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position: Double = 0     // continuous artwork crossfade driver
    @State private var displayedPage = 0        // settled page the foreground + dots show
    @State private var gestureStart: Double?
    @State private var isDragging = false

    // Pulls tvOS launch focus onto the hero's Play button instead of the `.sidebarAdaptable`
    // menu. Home loads async (skeleton first), so the menu claims focus on cold launch before
    // the hero exists; setting this `@FocusState` when the carousel mounts yanks focus across
    // from the system sidebar (a declarative `prefersDefaultFocus`/`resetFocus` can't — it only
    // re-resolves *within* its own scope). Unused on iOS — `.focused` is tvOS-gated below.
    @FocusState private var heroPlayFocused: Bool

    private var regularWidth: Bool { idiom.usesLandscapeHeroBand }
    private var count: Int { entries.count }

    var body: some View {
        GeometryReader { proxy in
            content(size: proxy.size)
        }
        .heroBandFrame(regularWidth: regularWidth)
        #if os(tvOS)
        // The carousel only mounts once the feed has loaded, so this fires after the menu's
        // cold-launch focus claim — moving focus onto the hero's Play button (collapsing the
        // menu). Deferred a runloop so the focus system has settled the menu's claim first.
        .onAppear { Task { @MainActor in heroPlayFocused = true } }
        #endif
        // Compare ids (not entries) so a favorite toggle doesn't reset the page; only a
        // changed entry set snaps back to the first page.
        .onChange(of: entries.map(\.id)) {
            position = 0; displayedPage = 0; gestureStart = nil; isDragging = false
        }
    }

    private func content(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            CrossfadeArtwork(position: position, entries: entries, session: session, regularWidth: regularWidth)
                // Stretchy hero: a pull-down zooms the artwork up from its bottom edge to
                // fill the rubber-band gap instead of exposing the app background. Only the
                // artwork scales — the title/actions stay put. `scaleEffect` is a render
                // transform, so it can't feed the geometry it's driven by back into layout.
                .scaleEffect(1 + overscroll / size.height, anchor: .bottom)

            // Use the band's real laid-out height (the geometry proxy), not a width-derived
            // value — on tvOS the band is a viewport fraction, not `width / aspectRatio`.
            heroBandScrim(
                regularWidth: regularWidth,
                bandWidth: size.width,
                bandHeight: size.height
            )

            // Hidden while dragging (removed → fades out); on a settled page change its `.id`
            // flips and SwiftUI crossfades the new page over the old. No manual opacity state.
            if !isDragging {
                #if os(tvOS)
                // No `.id` flip on tvOS: a changed identity would tear down the focused Play
                // button on every page, dropping focus so the next left/right couldn't page.
                // Keeping it stable retains focus and updates the content in place — the
                // artwork still crossfades via `CrossfadeArtwork`.
                foregroundLayer(page: displayedPage)
                #else
                foregroundLayer(page: displayedPage)
                    .id(displayedPage)
                    .transition(.opacity)
                #endif
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
            // Tuck the dots toward the artwork bottom edge on iPhone's poster band so they
            // stay clear of the foreground controls; iPad's landscape band has more room. tvOS
            // lifts them off the band's bottom edge so they sit above the peeking shelf.
            .padding(.bottom, idiom == .tv ? Space.s60 : (regularWidth ? Space.s12 : Space.s3))
        }
        .contentShape(Rectangle())
        // A horizontal-only UIKit pan: vertical swipes fall through to the Home ScrollView,
        // taps fall through to the Play/Favorite buttons. (A SwiftUI DragGesture can't do
        // both inside a ScrollView on iOS 18+.) No-op for a lone item.
        #if !os(tvOS)
        .gesture(
            HorizontalPanGesture(
                onChanged: { panChanged(translationX: $0, width: size.width) },
                onEnded: { panEnded(translationX: $0, velocityX: $1, width: size.width) },
                isEnabled: count > 1
            )
        )
        #endif
        #if os(tvOS)
        // Page the hero with the Siri Remote's left/right — replaces the old on-screen chevrons.
        // The focus engine consumes a directional press only when there's an adjacent focusable
        // in that direction, so this fires from the action row's OUTER edges (`HeroForeground`):
        // left while Play (leftmost) is focused, or right while Favorite (rightmost) is focused,
        // has no horizontal neighbour and lands here. Pressing toward the centre just moves focus
        // between the two buttons; up/down fall through to the focus engine / shelves below.
        // (Apple: focus navigation wins over `onMoveCommand`.)
        .onMoveCommand { direction in
            guard count > 1 else { return }
            switch direction {
            case .left:  commit(to: displayedPage - 1)
            case .right: commit(to: displayedPage + 1)
            default: break   // up/down fall through to the focus engine / scroll view
            }
        }
        #endif
    }

    private func foregroundLayer(page: Int) -> some View {
        let entry = entries[wrapping: page]
        return HeroForeground(
            entry: entry,
            session: session,
            regularWidth: regularWidth,
            isFavorite: entry.presentation.userData.isFavorite,
            playFocus: $heroPlayFocused,
            onPlay: { playback.play(entry.playTarget.id, in: session) },
            onToggleFavorite: { Task { await viewModel.toggleFavorite(for: entry.presentation.id) } }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .safeAreaPadding(.horizontal, HeroMetrics.foregroundHorizontalInset(idiom: idiom))
        .padding(.bottom, HeroMetrics.foregroundBottomInset(idiom: idiom))
        .tvFocusSection()
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
}

/// Just the artwork crossfade. `Animatable` on `position` is the crux: during a
/// `withAnimation` `position` change, SwiftUI interpolates `animatableData` and re-evaluates
/// `body` at each step, so the two images crossfade continuously rather than cutting between
/// the start and end states. Carries the iPad sidebar `backgroundExtensionEffect`.
private struct CrossfadeArtwork: View, Animatable {
    var position: Double
    let entries: [HomeHeroFeedEntry]
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
            HeroArtwork(item: entries[wrapping: lower].presentation, session: session, regularWidth: regularWidth)
            HeroArtwork(item: entries[wrapping: lower + 1].presentation, session: session, regularWidth: regularWidth)
                .opacity(frac)
        }
        .tvPlatformGated { $0.backgroundExtensionEffect(isEnabled: regularWidth) }
    }
}

private extension Array {
    /// Index wrapped into bounds for the infinite carousel. Caller guarantees a non-empty array.
    subscript(wrapping index: Int) -> Element { self[((index % count) + count) % count] }
}
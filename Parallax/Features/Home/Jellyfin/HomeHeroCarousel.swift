import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The Home carousel's page state, hoisted OUT of the carousel view because the hero's two halves
/// no longer live together: on iPhone/iPad the artwork is a fixed `heroBackdrop` behind the scroll
/// view while the foreground rides the scroll content, so a `@State` inside either half would be
/// invisible to the other. `HomeView` owns one of these and feeds both.
///
/// `@Observable` also keeps the insulation the old `@State` had: the continuous `position` is read
/// only by the artwork, so a crossfade tick re-renders the picture without touching the foreground
/// column, the page dots, or `HomeView`'s body.
@Observable
@MainActor
final class HomeHeroCarouselState {
    /// Continuous artwork crossfade driver — integers are settled pages, fractions are mid-fade.
    var position: Double = 0
    /// The settled page the foreground + dots show. Deliberately separate from `position`: the
    /// artwork crossfades continuously while the text swaps only on settle.
    var displayedPage = 0
    /// Drives the foreground's hide-while-dragging transition.
    var isDragging = false
    private var gestureStart: Double?

    /// A changed entry SET snaps back to the first page. Compared on ids by the caller, so a
    /// favorite toggle doesn't reset the carousel.
    func reset() {
        position = 0
        displayedPage = 0
        gestureStart = nil
        isDragging = false
    }

    func panChanged(translationX: CGFloat, width: CGFloat, reduceMotion: Bool) {
        let start = gestureStart ?? position
        gestureStart = start
        // Hide the foreground the moment the drag begins — any travel, not distance-based.
        // It stays hidden until release fades the page back in.
        if !isDragging {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isDragging = true }
        }
        position = clampedPage(start - Double(translationX) / Double(width), around: start)
    }

    func panEnded(translationX: CGFloat, velocityX: CGFloat, width: CGFloat, reduceMotion: Bool) {
        let start = gestureStart ?? position
        gestureStart = nil
        // Project with velocity so a flick commits (UIScrollView-style); one page per gesture.
        let projectedX = translationX + velocityX * 0.3
        commit(
            to: Int(clampedPage(start - Double(projectedX) / Double(width), around: start).rounded()),
            reduceMotion: reduceMotion
        )
    }

    /// Settle on `target`: spring the artwork there, and show the foreground for that page —
    /// re-inserting it after a drag (fade in) or crossfading its `.id` on auto-advance.
    func commit(to target: Int, reduceMotion: Bool) {
        // Reduce Motion: jump the artwork and swap the foreground instantly — the full-bleed crossfade
        // is the largest motion on Home, so it must not animate (mirrors the parallax/pill gating).
        withAnimation(reduceMotion ? nil : .organicSettle) { position = Double(target) }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            isDragging = false
            displayedPage = target
        }
    }

    /// One drag or flick moves at most one page: clamp the target to ±1 around where it began.
    private func clampedPage(_ raw: Double, around start: Double) -> Double {
        min(start + 1, max(start - 1, raw))
    }
}

/// The Home hero's PICTURE — the crossfading artwork, and nothing else. Handed to the screen's
/// `heroBackdrop` (iPhone/iPad, where it paints behind the scroll view) and to `HomeHeroCarousel`
/// (which forwards it to `HeroBand`, the mount that renders it on tvOS). Exactly one of those two
/// mounts it on any platform, so the images load once.
struct HomeHeroArtwork: View {
    /// Source-tagged, because the hero mixes servers: each page's artwork must resolve against the
    /// server the entry actually came from.
    let entries: [SourcedHeroEntry]
    let carousel: HomeHeroCarouselState
    let regularWidth: Bool

    var body: some View {
        // Home builds this before it knows whether the feed has heroes (the screen gates the mount
        // separately), and the carousel's modular indexing divides by the entry count.
        if !entries.isEmpty {
            CrossfadeArtwork(
                position: carousel.position,
                entries: entries,
                regularWidth: regularWidth
            )
        }
    }
}

/// Home hero — an Apple-TV-style crossfade carousel. This is the hero's IN-SCROLL half: the
/// foreground column, the page dots and the pan gesture, over the band-tall spacer `HeroBand`
/// reserves. The picture is `HomeHeroArtwork`, mounted by the screen's `heroBackdrop` on
/// iPhone/iPad and by `HeroBand` on tvOS.
///
/// The foreground's behaviour mirrors the Apple TV app — stateful, not distance-based, and it
/// leans on SwiftUI's own transitions rather than a hand-rolled crossfade:
///  • the moment a drag *begins* (any travel) the foreground is removed → it fades out;
///    releasing re-inserts the settled page → it fades back in. A binary hide-while-dragging.
///  • auto-advance keeps it shown but changes its `.id`, so the page change is a crossfade
///    (incoming over outgoing) with no hide.
///
/// Infinite both ways via modular indexing; native dots + pill in `HeroPageIndicator`.
struct HomeHeroCarousel: View {
    /// Source-tagged, because the hero mixes servers: each page's title logo and play target must
    /// resolve against the server the entry actually came from.
    let entries: [SourcedHeroEntry]
    let viewModel: HomeViewModel
    /// Page state, owned by `HomeView` so the fixed backdrop and this in-scroll half share it.
    let carousel: HomeHeroCarouselState
    /// Scroll channel from the Home `ScrollView`'s geometry, held as a reference type so a
    /// per-frame write invalidates ONLY the hero's transform wrappers and never this carousel's
    /// foreground. `adjustment` is signed: positive = pull-down rubber-band (stretchy zoom),
    /// negative = scrolled into the feed (half-speed parallax lag), 0 at rest.
    let scroll: HeroScrollState
    /// The SAME picture the screen's `heroBackdrop` paints. Passed through to `HeroBand`, which
    /// renders it on tvOS and ignores it on iPhone/iPad — see `HeroBand`'s `artwork` slot.
    let artwork: HomeHeroArtwork

    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Pulls tvOS launch focus onto the hero's Play button instead of the `.sidebarAdaptable`
    // menu. Home loads async (skeleton first), so the menu claims focus on cold launch before
    // the hero exists; setting this `@FocusState` when the carousel mounts yanks focus across
    // from the system sidebar (a declarative `prefersDefaultFocus`/`resetFocus` can't — it only
    // re-resolves *within* its own scope). Unused on iOS — `.focused` is tvOS-gated below.
    @FocusState private var heroPlayFocused: Bool
    // Tracks whether the next-chevron specifically holds focus, so a right-press only advances the
    // carousel when the chevron is focused — never on the ordinary Play↔Favorite↔chevron focus
    // hops. tvOS-only; inert on iOS (the chevron + `.focused` below are tvOS-gated).
    @FocusState private var chevronFocused: Bool

    private var regularWidth: Bool { idiom.usesLandscapeHeroBand }
    private var count: Int { entries.count }

    /// BlurHash of the SETTLED page's hero image, feeding the band's floor bleed. Tracks
    /// `displayedPage` (like the foreground and dots), not the continuous crossfade `position` —
    /// the bleed swaps with its own crossfade on settle (`HeroFloorBleed`'s `.id`/`.transition`).
    private var displayedBleedHash: String? {
        guard count > 0 else { return nil }
        let page = ((carousel.displayedPage % count) + count) % count
        return entries[page].entry.presentation.heroArtwork(regularWidth: regularWidth).ref?.blurHash
    }

    var body: some View {
        GeometryReader { proxy in
            content(size: proxy.size)
        }
        .heroBandFrame(regularWidth: regularWidth)
        // HeroForeground's action-row section (Play/Favorite/chevron) only spans its intrinsic
        // width, ending well short of the full 1920pt canvas — so pressing Up from a Continue
        // Watching tile at column index ≥ 2 (0-based) finds no focusable candidate in line above
        // it, a dead press. Wrapping this node — the `GeometryReader` this `.heroBandFrame` just
        // stretched to `.infinity` — gives the focus engine a full-width target that diverts Up
        // from ANY column into the nearest inner focusable. Nesting is legal, but `focusSection()`
        // has no "landing preference" — entry into a section is purely geometric-nearest, so which
        // control actually catches the diverted Up depends on the focused tile's column: it likely
        // lands the chevron (the rightmost control) rather than Play for shelf columns nearer the
        // trailing edge. That directional landing was evaluated on device and accepted. The action
        // row DOES now carry a default-focus pin on Play (`HeroForeground`'s focus scope +
        // `PrimaryPlayButton.tvPrefersDefaultFocus`), but that governs only DEFAULT-focus
        // resolution on screen open — user-directed Up presses still land geometric-nearest.
        // Same structural fix, same reasoning as `LibraryHeaderControls`'s full-width
        // section (device-verified there) — only the "lands on Play" claim was wrong.
        .tvFocusSection()
        #if os(tvOS)
        // The carousel only mounts once the feed has loaded, so this fires after the menu's
        // cold-launch focus claim — moving focus onto the hero's Play button (collapsing the
        // menu). Deferred a runloop so the focus system has settled the menu's claim first.
        .onAppear { Task { @MainActor in heroPlayFocused = true } }
        #endif
        // Compare ids (not entries) so a favorite toggle doesn't reset the page; a changed entry
        // set snaps back to the first page. `initial: true` because the page state now outlives
        // this view (it's hoisted to HomeView for the split hero): a hero-less interlude
        // (emptied feed, failure state) unmounts the carousel WITHOUT clearing the state, and a
        // later remount must not open on the previous feed's page.
        .onChange(of: entries.map(\.id), initial: true) {
            carousel.reset()
        }
    }

    private func content(size: CGSize) -> some View {
        // On iPhone/iPad `HeroBand` contributes only the band-tall spacer this foreground sits in —
        // the picture is the screen's `heroBackdrop`, behind the scroll view. On tvOS the same call
        // renders `artwork` in place and applies the scroll effects to it.
        HeroBand(scroll: scroll, floorBleedHash: displayedBleedHash) {
            artwork
        } foreground: {
            // FOREGROUND-BOUND transition: hidden while dragging (removed → fades out); on a
            // settled page change its `.id` flips and SwiftUI crossfades the new page over the
            // old. No manual opacity state — and the artwork keeps crossfading underneath.
            if !carousel.isDragging {
                #if os(tvOS)
                // No `.id` flip on tvOS: a changed identity would tear down the focused Play
                // button / next-chevron on every page, dropping focus so the next right-press
                // couldn't page. Keeping it stable retains focus and updates the content in place —
                // the artwork still crossfades via `CrossfadeArtwork`.
                foregroundLayer(page: carousel.displayedPage)
                #else
                foregroundLayer(page: carousel.displayedPage)
                    .id(carousel.displayedPage)
                    .transition(.opacity)
                #endif
            }
        }
        // BAND-WRAPPING chrome: the page dots as a bottom overlay (the gesture/move-command below
        // are the other band-wrapping pieces). One inset rule per idiom (`pageIndicatorBottomInset`)
        // so the dots sit a consistent, comfortable clearance above the band's bottom edge on every
        // platform instead of iPhone jamming them against the poster's bottom seam.
        .overlay(alignment: .bottom) {
            HeroPageIndicator(
                numberOfPages: count,
                currentPage: ((carousel.displayedPage % count) + count) % count,
                autoAdvanceInterval: 6,
                isPaused: carousel.isDragging,
                reduceMotion: reduceMotion,
                onAdvance: { carousel.commit(to: carousel.displayedPage + 1, reduceMotion: reduceMotion) }
            )
            .frame(maxWidth: .infinity)
            .padding(.bottom, HeroMetrics.pageIndicatorBottomInset(idiom: idiom))
        }
        .contentShape(Rectangle())
        // A horizontal-only UIKit pan: vertical swipes fall through to the Home ScrollView,
        // taps fall through to the Play/Favorite buttons. (A SwiftUI DragGesture can't do
        // both inside a ScrollView on iOS 18+.) No-op for a lone item.
        #if !os(tvOS)
        .gesture(
            HorizontalPanGesture(
                onChanged: { carousel.panChanged(translationX: $0, width: size.width, reduceMotion: reduceMotion) },
                onEnded: { carousel.panEnded(translationX: $0, velocityX: $1, width: size.width, reduceMotion: reduceMotion) },
                isEnabled: count > 1
            )
        )
        #endif
        #if os(tvOS)
        // Advance ONLY on a right-press while the next-chevron itself is focused (`chevronFocused`).
        // Without that gate, a right-press at the rightmost focusable falls through here regardless,
        // so any sequence ending on the chevron could page; gating on the chevron's own focus makes
        // "move the carousel" mean exactly "focused chevron + right-click" and nothing else. Ordinary
        // Play↔Favorite↔chevron focus hops are consumed by focus navigation and never reach here.
        // Left is deliberately unhandled (from Play it reveals the `.sidebarAdaptable` sidebar);
        // forward-only by design (auto-advance still cycles); up/down fall through to the shelves.
        .onMoveCommand { direction in
            guard count > 1, direction == .right, chevronFocused else { return }
            carousel.commit(to: carousel.displayedPage + 1, reduceMotion: reduceMotion)
        }
        #endif
    }

    @ViewBuilder
    private func foregroundLayer(page: Int) -> some View {
        let sourced = entries[wrapping: page]
        let entry = sourced.entry
        let item = entry.presentation
        // Every page resolves ITS OWN server: the hero mixes servers, so a screen-level session
        // would bind page 2's artwork and play target to page 1's host and token.
        if let session = sourced.jellyfinSession {
            // Placement (readable column + insets) and the action-row focus section now live in
            // `HeroBand`/`HeroForeground`; this just binds the slots for the settled page.
            HeroForeground(
                eyebrow: entry.eyebrow.rawValue,
                title: HeroTitle(item: item, session: session, idiom: idiom, scale: .home)
            ) {
                if let overview = AdaptiveHeroOverview(item: item) {
                    overview
                } else if let meta = item.heroMetadataLine {
                    Text(meta)
                        .font(.cardHeaderSubtitle)
                        .foregroundStyle(.white)
                        // Same contour as the overview it stands in for (bare wide band).
                        .heroTypeContour(idiom: idiom)
                }
            } actions: {
                primaryPlay(entry, session: session)
                FavoriteActionButton(isFavorite: item.userData.isFavorite) {
                    Task { await viewModel.toggleFavorite(for: item.id, source: sourced.source.sourceID) }
                }
                #if os(tvOS)
                // The forward pager affordance — the RIGHTMOST focusable in the action row. A bare
                // chevron at rest (`bareUntilFocused`); on focus it lights up to the same white platter
                // + lift as Favorite. Select advances; so does a right-press, but ONLY because the
                // chevron is the focused control — `onMoveCommand` below gates on `chevronFocused`, so a
                // right-press during ordinary Play→Favorite→chevron navigation never pages. There is no
                // left/previous counterpart by design (left from Play just reveals the sidebar). Shown
                // only for a real carousel.
                if count > 1 {
                    CircleGlassButton(
                        systemImage: "chevron.right",
                        accessibilityLabel: "Next featured item",
                        bareUntilFocused: true
                    ) {
                        carousel.commit(to: carousel.displayedPage + 1, reduceMotion: reduceMotion)
                    }
                    .focused($chevronFocused)
                }
                #endif
            }
        }
    }

    /// Play pill, bound to the carousel's `@FocusState` on tvOS so the carousel can pull launch
    /// focus onto it (out of the `.sidebarAdaptable` menu) when the feed mounts; inert on iOS.
    @ViewBuilder
    private func primaryPlay(_ entry: HomeHeroFeedEntry, session: Session) -> some View {
        let button = PrimaryPlayButton(
            title: entry.playButtonTitle,
            fillWidth: false,
            layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle(for: .episodeNumbered)
        ) {
            playback.play(entry.playTarget.id, in: session)
        }
        #if os(tvOS)
        button.focused($heroPlayFocused)
        #else
        button
        #endif
    }

}

/// Full-bleed artwork for one hero item — the crossfading layers inside `CrossfadeArtwork`,
/// which stacks two of these. The iPad sidebar bleed is owned by `HeroBackdrop`.
private struct HeroArtwork: View {
    /// Source-tagged so each page fetches from ITS server. A hero mixing two servers with one
    /// screen-level session would request page 2's backdrop from page 1's host and token.
    let sourced: SourcedHeroEntry
    let regularWidth: Bool

    private var artwork: (ref: ImageRef?, kind: ImageKind) {
        sourced.entry.presentation.heroArtwork(regularWidth: regularWidth)
    }

    var body: some View {
        if let session = sourced.jellyfinSession {
            MediaImage(
                jellyfin: artwork.ref,
                session: session,
                maxWidth: 1600,
                aspectRatio: HeroMetrics.bandAspectRatio(regularWidth: regularWidth),
                style: .fill
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}

/// Just the artwork crossfade. `Animatable` on `position` is the crux: during a
/// `withAnimation` `position` change, SwiftUI interpolates `animatableData` and re-evaluates
/// `body` at each step, so the two images crossfade continuously rather than cutting between
/// the start and end states. The legibility veil and the iPad sidebar bleed are both owned by
/// `HeroBackdrop` (one layer out), keeping this a pure crossfade — its per-tick body re-evaluation
/// rebuilds nothing but the two images.
private struct CrossfadeArtwork: View, Animatable {
    var position: Double
    let entries: [SourcedHeroEntry]
    let regularWidth: Bool

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let lower = Int(floor(position))
        let frac = position - Double(lower)
        return ZStack {
            HeroArtwork(sourced: entries[wrapping: lower], regularWidth: regularWidth)
            HeroArtwork(sourced: entries[wrapping: lower + 1], regularWidth: regularWidth)
                .opacity(frac)
        }
    }
}

private extension Array {
    /// Index wrapped into bounds for the infinite carousel. Caller guarantees a non-empty array.
    subscript(wrapping index: Int) -> Element { self[((index % count) + count) % count] }
}

// MARK: - Preview harness

/// Permanent diagnostic for the carousel's PAGE-DOT placement — the real carousel needs a
/// `Session`, so this rebuilds the band's bottom chrome over a mock backdrop + the actual action
/// row (Play pill + Favorite) so the dots' clearance above the band's bottom edge can be judged in
/// pixels. The fixed-layout canvas IS the 2:3 poster band, so the canvas bottom == the band's
/// bottom edge (the seam where the hero meets the shelves on iPhone). `.fixedLayout` defaults the
/// idiom to `.compact`, which is exactly the case that was jamming the dots against that seam.
#Preview("Home hero · pager chrome (compact)", traits: .fixedLayout(width: 393, height: 590)) {
    // Mirrors the shipping split: the picture is a fixed backdrop behind the scroll surface, the
    // foreground and dots ride the band-tall spacer in front of it.
    let art = LinearGradient(
        colors: [Color(red: 0.16, green: 0.10, blue: 0.28),
                 Color(red: 0.46, green: 0.20, blue: 0.30)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    return HeroBand {
        art
    } foreground: {
        VStack(alignment: .leading, spacing: Space.s12) {
            HeroEyebrowLabel(text: "FEATURED")
            Text("Orbital Decay")
                .scaledFont(32, relativeTo: .largeTitle, weight: .heavy)
                .foregroundStyle(.white)
            Text("A crew on humanity's last orbital station races to prevent a cascade failure.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
            HStack(spacing: ActionRow.gap) {
                PrimaryPlayButton(title: "Play", fillWidth: false) {}
                CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") {}
            }
            .padding(.top, Space.s8)
        }
    }
    .heroBandFrame(regularWidth: false)
    .overlay(alignment: .bottom) {
        HeroPageIndicator(
            numberOfPages: 5, currentPage: 1, autoAdvanceInterval: 6,
            isPaused: false, reduceMotion: false, onAdvance: {}
        )
        .frame(maxWidth: .infinity)
        .padding(.bottom, HeroMetrics.pageIndicatorBottomInset(idiom: .compact))
    }
    .heroBackdrop(scroll: nil, artwork: art)
}

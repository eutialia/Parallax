import SwiftUI
import ParallaxJellyfin
import ParallaxCore

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
    /// Source-tagged, because the hero mixes servers: each page's artwork, title logo, and play
    /// target must resolve against the server the entry actually came from.
    let entries: [SourcedHeroEntry]
    let viewModel: HomeViewModel
    /// Scroll channel from the Home `ScrollView`'s geometry, held as a reference type so a per-frame
    /// write invalidates ONLY its two readers inside `HeroBand` — the parallax wrapper and the
    /// pull-down stretch layer — and never this carousel's foreground. `adjustment` is signed:
    /// positive = pull-down rubber-band (stretchy zoom), negative = scrolled into the feed
    /// (half-speed parallax lag), 0 at rest — the two effects are mutually exclusive by sign.
    let scroll: HeroScrollState

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
        let page = ((displayedPage % count) + count) % count
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
        // trailing edge. Forcing Play as the target would take `prefersDefaultFocus` scoped through
        // a `@Namespace` on the action row; that lever stays UNBUILT because the chevron landing was
        // evaluated on device and accepted — build it only if the landing starts to annoy in
        // practice. Same structural fix, same reasoning as `LibraryHeaderControls`'s full-width
        // section (device-verified there) — only the "lands on Play" claim was wrong.
        .tvFocusSection()
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
        // `scroll` feeds both of `HeroBand`'s scroll effects — the artwork parallax (inside the
        // slot, under the legibility veil) and the pull-down stretch (outside the sidebar
        // extension, which clips to bounds; regressed twice as "background exposed on pull-down").
        // Both wrappers live in `HeroBand` now, so the slot just hands over the raw artwork.
        HeroBand(scroll: scroll, floorBleedHash: displayedBleedHash) {
            CrossfadeArtwork(
                position: position,
                entries: entries,
                regularWidth: regularWidth
            )
        } foreground: {
            // FOREGROUND-BOUND transition: hidden while dragging (removed → fades out); on a
            // settled page change its `.id` flips and SwiftUI crossfades the new page over the
            // old. No manual opacity state — and the artwork keeps crossfading underneath.
            if !isDragging {
                #if os(tvOS)
                // No `.id` flip on tvOS: a changed identity would tear down the focused Play
                // button / next-chevron on every page, dropping focus so the next right-press
                // couldn't page. Keeping it stable retains focus and updates the content in place —
                // the artwork still crossfades via `CrossfadeArtwork`.
                foregroundLayer(page: displayedPage)
                #else
                foregroundLayer(page: displayedPage)
                    .id(displayedPage)
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
                currentPage: ((displayedPage % count) + count) % count,
                autoAdvanceInterval: 6,
                isPaused: isDragging,
                reduceMotion: reduceMotion,
                onAdvance: { commit(to: displayedPage + 1) }
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
                onChanged: { panChanged(translationX: $0, width: size.width) },
                onEnded: { panEnded(translationX: $0, velocityX: $1, width: size.width) },
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
            commit(to: displayedPage + 1)
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
                        commit(to: displayedPage + 1)
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
            layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle
        ) {
            playback.play(entry.playTarget.id, in: session)
        }
        #if os(tvOS)
        button.focused($heroPlayFocused)
        #else
        button
        #endif
    }

    private func panChanged(translationX: CGFloat, width: CGFloat) {
        let start = gestureStart ?? position
        gestureStart = start
        // Hide the foreground the moment the drag begins — any travel, not distance-based.
        // It stays hidden until release fades the page back in.
        if !isDragging { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isDragging = true } }
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
        // Reduce Motion: jump the artwork and swap the foreground instantly — the full-bleed crossfade
        // is the largest motion on Home, so it must not animate (mirrors the parallax/pill gating above).
        withAnimation(reduceMotion ? nil : .organicSettle) { position = Double(target) }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            isDragging = false
            displayedPage = target
        }
    }
}

/// Full-bleed artwork for one hero item — the crossfading layers inside `CrossfadeArtwork`,
/// which stacks two of these. The iPad sidebar `backgroundExtensionEffect` is owned by `HeroBand`.
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
/// the start and end states. The legibility veil and the sidebar extension are both owned by
/// `HeroBand` (one layer out), keeping this a pure crossfade — its per-tick body re-evaluation
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
    HeroBand {
        LinearGradient(
            colors: [Color(red: 0.16, green: 0.10, blue: 0.28),
                     Color(red: 0.46, green: 0.20, blue: 0.30)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
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
}

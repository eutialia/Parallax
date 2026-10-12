import SwiftUI
import ParallaxJellyfin
import ParallaxCore
import ParallaxFeatures

/// `HomeView.content`'s branch discriminator — see `crossfadeStateSwap`.
private enum HomeContentPhase: Hashable {
    case skeleton
    case loaded
    case failed
    case unavailable
}

/// Home renders `AppModel.home`, which both navigation roots load through
/// `AppModel.loadSources()`; the view itself fetches nothing.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(\.appIdiom) private var idiom
    // Reference-type scroll channel: the per-frame scroll value lives on an @Observable so a
    // scroll write invalidates ONLY `HeroBand`'s artwork-transform wrappers that read it,
    // not HomeView's body or the whole carousel (title, actions, dots). When this was a plain
    // `@State CGFloat` passed into the carousel, every scroll frame re-evaluated the entire hero —
    // reloading the foreground's logo image on iOS (where parallax is live) and doing the same
    // dead work on tvOS (parallax is 0 there). See `HeroScrollState`.
    @State private var heroScroll = HeroScrollState()
    // The carousel's page state, owned HERE because the hero's two halves sit on opposite sides of
    // the scroll view: the picture is a fixed backdrop behind it, the foreground + dots ride the
    // content. Both read this one object — see `HomeHeroCarouselState`.
    @State private var heroCarousel = HomeHeroCarouselState()

    /// Home aggregates every signed-in server, so there is no single "the session" for this
    /// screen — the per-item source rides on each `SourcedItem`. nil is the SMB-only placeholder,
    /// or the bootstrap skeleton.
    private var viewModel: HomeViewModel? { app.home }

    var body: some View {
        ScrollView {
            content
                // iOS-only crossfade of the whole skeleton→loaded/failed/unavailable swap; see
                // `crossfadeStateSwap`. tvOS hard-cuts as before.
                .crossfadeStateSwap(contentPhase)
        }
        // Feed the hero band its stretch + parallax scroll channel (shared with the detail
        // headers — see `heroScrollChannel` for the geometry math).
        .heroScrollChannel(heroScroll)
        .scrollClipDisabled(true)
        // Start at the very top so the full-bleed tvOS hero opens at full height, not mid-scroll
        // (the focus engine otherwise leaves the launch position low until a focus change re-runs
        // its scroll-to-focus). No-op on iOS, where the top is already the default anchor.
        .defaultScrollAnchor(.top)
        // Suppress iOS 26's automatic top scroll-edge fade — the hero paints flush under the
        // status bar (`.ignoresSafeArea(.top)`), so the soft edge effect reads as a stray fade
        // on the artwork (measured 2026-07). A `.soft` re-test in the 2026-08-10 WWDC25-323
        // audit (Landmarks keeps the effect on its hero) was CONFOUNDED — the artifact blamed
        // on it turned out to be HeroVeilTreatments' centering bug — and was reverted without a
        // clean verdict; re-judge `.soft` only on a clean band if it ever matters. Gated on the
        // bleed: with no hero the shelves DO scroll under the (transparent) bar and want the
        // system's legibility fade back. Matches the movie/series detail screens.
        #if !os(tvOS)
        .scrollEdgeEffectHidden(showsHeroBleed, for: .top)
        #endif
        // Fill the detail width even while the loading state's content is small —
        // otherwise on a cold launch the ScrollView collapses to its content's ideal
        // width (~100pt for the loading spinner) until a later layout pass, showing a
        // narrow strip. Greedy frame pins it to the proposed width from the first pass.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The hero's PICTURE, pinned behind the scroll content (no-op on tvOS, whose band carries
        // its own). Ahead of `heroScreenSafeArea` so it inherits the dropped top inset and paints
        // under the status bar, and ahead of `screenFloor` so the floor stays behind it — keeping
        // the floor screen-sized and screen-pinned instead of scrolling with the page.
        // Gated on the hero actually existing: `showsHeroBleed` is also true for the SKELETON,
        // which has no feed to draw.
        .heroBackdrop(active: showsHeroBackdrop, scroll: heroScroll, artwork: heroArtwork)
        // tvOS bleeds the hero horizontally too (overscan) and measures the true screen height into
        // `\.heroViewportHeight` so the band fills the whole screen; the shelves re-inset via
        // `tvContentInset()` below. iOS only drops the top inset (status-bar bleed). The bleed is
        // CONDITIONAL: it exists for the hero band, and the hero can be absent at runtime (empty
        // hero feed from the server, or the feed call failing to a StatusStateView) — bleeding then
        // parks the shelves/failure text at the raw screen top, colliding with the tvOS
        // collapsed-sidebar pill. With no hero the screen rides the normal safe area — the
        // SYSTEM's chrome-honoring rest (120pt at a tvOS tab root), deliberately not the walls'
        // 100pt bypass rest: the shelves are a different surface family with no pushed sibling
        // to match, and the fallback state prefers the system's own answer. The skeleton keeps the bleed (its hero
        // placeholder is full-bleed like the real band) — so a HERO reveal doesn't shift, while
        // the rarer hero-less reveal drops the band height once at the swap, by design.
        .heroScreenSafeArea(active: showsHeroBleed)
        // Paint the screen floor in the content so the scroll region matches the chrome and lifts
        // with the system when the iPad window is elevated (see `screenFloor`). The hero draws
        // opaque artwork on top, so this only shows in the loading state and under any gaps.
        .screenFloor()
        // Keep a (transparent, title-less) navigation bar rather than hiding it: the
        // hero still bleeds under it via `ignoresSafeArea` + `scrollEdgeEffectHidden`,
        // but the bar gives the pushed detail's back button a shared bar to cross-fade
        // with. Without it (bar hidden) the zoom-transition back button has no
        // counterpart and slides across the screen on dismiss. The BACKGROUND hide is
        // hero-only: on a hero-less feed the shelves scroll under the bar, and the
        // system's automatic material is what keeps that edge legible.
        .toolbarBackgroundVisibility(showsHeroBleed ? .hidden : .automatic, for: .navigationBar)
        .itemDetailNavigation()
    }

    /// Whether the scroll surface should bleed for a full-bleed hero band — see the
    /// `heroScreenSafeArea(active:)` call site. Skeleton bleeds (its hero placeholder is
    /// full-bleed); loaded bleeds only when the hero feed actually has entries; the failure and
    /// SMB-only placeholders have no band and honor the safe area.
    /// DEBUG layout arg: force the hero-less Home (`-herolessHome`) against a server whose feed
    /// HAS heroes — the empty-hero state depends entirely on server data, so scripted
    /// verification of this layout needs the switch. `static let` so argv is scanned once, not
    /// on every body evaluation (launch arguments can't change mid-process anyway).
    #if DEBUG
    private static let forceHeroless = ProcessInfo.processInfo.arguments.contains("-herolessHome")
    #else
    private static let forceHeroless = false
    #endif

    /// THE hero-presence predicate — the body's carousel `if`, the safe-area bleed, and the
    /// hero-less headroom all derive from this one answer so they can never disagree (a bleed
    /// without a band parks content under the tvOS pill; a band without the bleed reserves a
    /// stray safe-area strip above it).
    private func showsHero(_ vm: HomeViewModel) -> Bool {
        !vm.heroFeed.isEmpty && !Self.forceHeroless
    }

    private var showsHeroBleed: Bool {
        switch contentPhase {
        case .skeleton: return true
        case .loaded: return viewModel.map(showsHero) ?? false
        case .failed, .unavailable: return false
        }
    }

    /// Whether the fixed hero backdrop should paint. Narrower than `showsHeroBleed`, which also
    /// covers the SKELETON: the skeleton draws its own full-bleed placeholder and has no feed for
    /// the backdrop to render.
    private var showsHeroBackdrop: Bool {
        guard case .loaded = contentPhase, let vm = viewModel else { return false }
        return showsHero(vm)
    }

    /// The hero's picture — ONE expression, handed to both halves: the `heroBackdrop` behind the
    /// scroll view paints it, and `HomeHeroCarousel` forwards the same value to `HeroBand` (which
    /// renders it on tvOS). Safe to build with an empty feed; it draws nothing.
    private var heroArtwork: HomeHeroArtwork {
        HomeHeroArtwork(
            entries: viewModel?.heroFeed ?? [],
            carousel: heroCarousel,
            regularWidth: idiom.usesLandscapeHeroBand
        )
    }

    /// Discriminates which top-level branch of `content` is showing, for `crossfadeStateSwap`.
    /// Deliberately NOT `vm.state` itself (payload-carrying, not `Hashable`) — both loading
    /// branches (the pre-session bootstrap skeleton and `vm.state`'s own `.idle`/`.loading`)
    /// collapse to the same `.skeleton` case, since they render the identical placeholder.
    private var contentPhase: HomeContentPhase {
        if let vm = viewModel {
            switch vm.state {
            case .idle, .loading: return .skeleton
            case .loaded: return .loaded
            case .failed: return .failed
            }
        } else if router.destination == .home, router.activeServerID == nil {
            return .unavailable
        } else {
            return .skeleton
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            @Bindable var vm = vm
            Group {
            switch vm.state {
            case .idle, .loading:
                HomeLoadingSkeleton()
            case .loaded:
                // A plain VStack, NOT LazyVStack: the tvOS hero is a full-viewport band, so the
                // shelves sit entirely below the fold — a lazy stack never builds them, leaving
                // nothing focusable to move DOWN to (focus got stuck in the hero) and an unstable
                // content height that threw off the launch scroll position. Eager build keeps the
                // shelves focusable and the height fixed; the feed is only a hero + two shelves, so
                // there's nothing to lazily defer. Parallax insulation still holds — `HomeShelves`
                // is its own view, so it isn't re-evaluated on the hero's per-frame scroll writes.
                VStack(alignment: .leading, spacing: Space.s30) {
                    if showsHero(vm) {
                        HomeHeroCarousel(
                            entries: vm.heroFeed,
                            viewModel: vm,
                            carousel: heroCarousel,
                            scroll: heroScroll,
                            artwork: heroArtwork
                        )
                    }
                    HomeShelves(viewModel: vm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Hero-less iPhone/iPad: with the band gone the first shelf header sat flush
                // against the status/nav bar — give it section headroom. tvOS already rests
                // below the pill band via the honored safe area; the hero case fills the top.
                .padding(.top, showsHeroBleed || idiom == .tv ? 0 : Space.s22)
                .padding(.bottom, Space.s30)
            case .failed(let message):
                StatusStateView.failure("Couldn't load Home", message: message)
            }
            }
            .alert(
                "Couldn't update favorite",
                isPresented: $vm.isShowingFavoriteError,
                presenting: vm.favoriteErrorMessage
            ) { _ in
                Button("Dismiss", role: .cancel) { }
            } message: { message in
                Text(message)
            }
        } else if router.destination == .home, router.activeServerID == nil {
            // Reached Home with no Jellyfin session feeding it — an SMB-only /
            // non-Jellyfin config. Distinct from the skeleton below, which is the
            // transient bootstrapping state (still resolving the active session).
            // `StatusStateView` fills the viewport and centers itself, so it reads as a
            // deliberate empty state rather than content pinned under the status bar.
            HomeUnavailableView()
        } else {
            HomeLoadingSkeleton()
        }
    }
}

/// The progress-driven shelves below the hero (Continue Watching · Next Up, or the
/// empty state). A standalone view — not an inline `@ViewBuilder` — so it's insulated
/// from `HomeView`'s per-frame `heroScroll` writes: only the carousel's artwork layer
/// needs them, and rebuilding these shelves on every scroll frame is wasted work.
private struct HomeShelves: View {
    let viewModel: HomeViewModel

    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let vm = viewModel
        // Everything below the full-bleed hero stays inside the tvOS title-safe
        // region (`tvContentInset()`), so focusable shelf cards aren't clipped by
        // overscan. No-op on iOS.
        VStack(alignment: .leading, spacing: Space.s30) {
            if !vm.continueWatching.isEmpty {
                MetadataRow(title: "Continue Watching", items: vm.continueWatching, tileWidth: AppLayout.shelfTileWidth(idiom: idiom)) { sourced in
                    homeShelfTile(sourced, showProgress: true)
                }
                .prefetchArtwork(groups: shelfArtworkGroups(vm.continueWatching))
            }
            if !vm.nextUp.isEmpty {
                MetadataRow(title: "Next Up", items: vm.nextUp, tileWidth: AppLayout.shelfTileWidth(idiom: idiom)) { sourced in
                    homeShelfTile(sourced, showProgress: false)
                }
                .prefetchArtwork(groups: shelfArtworkGroups(vm.nextUp))
            }
            if vm.heroFeed.isEmpty && vm.continueWatching.isEmpty && vm.nextUp.isEmpty {
                StatusStateView(
                    title: "Nothing here yet",
                    systemImage: "play.slash",
                    message: "Play something from your library and it will appear here."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvContentInset()
        // Dim + crossfade the progress-driven shelves while `refresh()` re-pulls
        // them after playback — same recipe as the library grid's sort/filter.
        .staleWhileRevalidate(isRefreshing: vm.isRefreshing, reduceMotion: reduceMotion)
    }

    // MARK: - Item rendering helpers

    /// The exact artwork URLs the shelf tiles will request, bucketed per server — the same ref
    /// (`homeShelfImageRef`), ceiling, render width, scale, and aspect as the tile, via the shared
    /// `ArtworkPrefetch` so the warm-up hits the SAME cache key the tiles read (any drift = a wasted
    /// double-download). Bucketed because a mixed-server shelf has no single host or pipeline.
    private func shelfArtworkGroups(_ items: [SourcedItem]) -> [ArtworkPrefetchGroup] {
        ArtworkPrefetch.groups(
            for: items,
            session: \.jellyfinSession,
            imageRef: { $0.item.homeShelfImageRef },
            ceiling: HomeShelf.imageMaxWidth,
            renderPointWidth: AppLayout.shelfTileWidth(idiom: idiom),
            displayScale: displayScale,
            aspectRatio: MediaImage.poster
        )
    }

    @ViewBuilder
    private func homeShelfTile(_ sourced: SourcedItem, showProgress: Bool) -> some View {
        // Every tile resolves ITS OWN server: Home mixes servers now, so a screen-level session
        // would build server B's poster URL against server A's host and bearer token.
        // `jellyfinSession` is non-nil for everything Home can hold today — SMB has no
        // watch-progress feed to contribute — so the missing branch drops nothing; it exists
        // because the shelves are typed on the source-agnostic `SourcedItem` that Search will also
        // carry file-source hits in.
        if let session = sourced.jellyfinSession {
            let item = sourced.item
            // Home is play-first: a movie tile plays (and resumes) immediately instead of opening
            // detail. Episodes already play; series still need detail to pick an episode.
            ItemNavigator(item: item, session: session, movieTap: .plays) {
                // The footer-only tile (metadata nil ⇒ thumbnail alone): a Home poster carries its
                // caption + progress ON the image, no below-tile text (the one-text-region law).
                MediaTile(
                    title: item.displayTitle,
                    imageRef: item.homeShelfImageRef,
                    session: session,
                    aspectRatio: MediaImage.poster,
                    maxImageWidth: HomeShelf.imageMaxWidth,
                    // Trim the request to the tile's actual point width × display scale (capped at
                    // the @3x ceiling), so a 2x panel doesn't decode the full @3x thumb.
                    maxImageRenderWidth: AppLayout.shelfTileWidth(idiom: idiom),
                    footer: MediaThumbnail.Footer.make(
                        caption: homeShelfCaption(item, showProgress: showProgress),
                        progress: showProgress ? tileProgress(item) : nil
                    ),
                    metadata: nil
                )
            }
        }
    }

    private func homeShelfCaption(_ item: Item, showProgress: Bool) -> String? {
        switch item {
        case .episode(let e):
            if showProgress {
                // Continue Watching — time remaining only; no total runtime fallback.
                return e.shelfFooterCaption(showRuntimeLength: false)
            }
            // Next Up — episode index + total runtime.
            return e.shelfFooterCaption(showTimeRemaining: false)
        case .movie, .series:
            guard showProgress,
                  let minutes = item.userData.remainingMinutes(runtime: item.runtime) else { return nil }
            return "\(minutes) min left"
        }
    }

    private func tileProgress(_ item: Item) -> Double? {
        switch item {
        case .episode(let e):
            return e.shelfPlaybackProgress
        case .movie:
            let runtimeTicks = item.runtime.map { Int64($0.components.seconds) * 10_000_000 }
            return item.userData.playedFraction(runtimeTicks: runtimeTicks)
        case .series:
            return nil
        }
    }
}

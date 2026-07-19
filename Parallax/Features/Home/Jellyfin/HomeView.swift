import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// `HomeView.content`'s branch discriminator — see `crossfadeStateSwap`.
private enum HomeContentPhase: Hashable {
    case skeleton
    case loaded
    case failed
    case unavailable
}

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(LaunchGate.self) private var launchGate
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(UserDataActions.self) private var userDataActions
    /// Supplied by the tvOS launch gate (`FocusRootView`), which loads the feed up front so the
    /// hero is on screen — and focusable — the instant the sidebar appears. When set, the view
    /// skips its own fetch. iOS leaves this nil and self-loads in `.task` as before.
    private let preloaded: (session: Session, viewModel: HomeViewModel)?
    @State private var viewModel: HomeViewModel?
    @State private var session: Session?
    // Reference-type scroll channel: the per-frame scroll value lives on an @Observable so a
    // scroll write invalidates ONLY `HeroBand`'s artwork-transform wrappers that read it,
    // not HomeView's body or the whole carousel (title, actions, dots). When this was a plain
    // `@State CGFloat` passed into the carousel, every scroll frame re-evaluated the entire hero —
    // reloading the foreground's logo image on iOS (where parallax is live) and doing the same
    // dead work on tvOS (parallax is 0 there). See `HeroScrollState`.
    @State private var heroScroll = HeroScrollState()

    init(preloaded: (session: Session, viewModel: HomeViewModel)? = nil) {
        self.preloaded = preloaded
    }

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
        // on the artwork. Matches the movie/series detail screens.
        #if !os(tvOS)
        .scrollEdgeEffectHidden(true, for: .top)
        #endif
        // Fill the detail width even while the loading state's content is small —
        // otherwise on a cold launch the ScrollView collapses to its content's ideal
        // width (~100pt for the loading spinner) until a later layout pass, showing a
        // narrow strip. Greedy frame pins it to the proposed width from the first pass.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // tvOS bleeds the hero horizontally too (overscan) and measures the true screen height into
        // `\.heroViewportHeight` so the band fills the whole screen; the shelves re-inset via
        // `tvContentInset()` below. iOS only drops the top inset (status-bar bleed).
        .heroScreenSafeArea()
        // Paint the screen floor in the content so the scroll region matches the chrome and lifts
        // with the system when the iPad window is elevated (see `screenFloor`). The hero draws
        // opaque artwork on top, so this only shows in the loading state and under any gaps.
        .screenFloor()
        // Keep a (transparent, title-less) navigation bar rather than hiding it: the
        // hero still bleeds under it via `ignoresSafeArea` + `scrollEdgeEffectHidden`,
        // but the bar gives the pushed detail's back button a shared bar to cross-fade
        // with. Without it (bar hidden) the zoom-transition back button has no
        // counterpart and slides across the screen on dismiss.
        .toolbarBackground(.hidden, for: .navigationBar)
        .itemDetailNavigation()
        // Keyed on `libraryReloadToken`, NOT raw `activeServerID`: an SMB-only cold launch keeps
        // `activeServerID` nil across the bootstrap→home flip, so a task keyed on it fires once
        // during `.bootstrapping` (releasing nothing, since destination isn't `.home` yet) and never
        // re-fires — the launch reveal then hangs until the 15s watchdog. The token folds in
        // `hasAuxiliarySources`, so it moves when SMB-only home resolves and re-fires `loadFeed`
        // (which then releases the hold). A Jellyfin switch still moves the token via `activeServerID`.
        .task(id: router.libraryReloadToken) { await loadFeed() }
        // A finished playback session moved progress (incl. the new prev/next episode
        // jumps), so re-pull the progress-driven shelves the moment the player dismisses.
        // Home stays MOUNTED under the player layer/cover, so its `.task`/`.onAppear`
        // never re-fire — `playback.request` clearing is the only "back from watching"
        // edge. Guarded to the present→dismiss transition (oldID != nil, newID == nil).
        .onChange(of: playback.request?.id) { oldID, newID in
            if oldID != nil, newID == nil {
                Task { await viewModel?.refresh() }
            }
        }
        // Auto-recover the error screen when the network returns (or the app foregrounds online)
        // instead of stranding the user on a stale "Couldn't load Home". Gated on `isStalled`, so a
        // loaded feed is never re-pulled. Event-based — no pull-to-refresh.
        .recoversFromOffline(isStalled: viewModel?.isStalled ?? false) { await viewModel?.load() }
    }

    /// Per-source feed load for the `.task(id: libraryReloadToken)`. tvOS adopts the launch gate's
    /// preloaded feed and skips the fetch; iOS self-loads once the session is active. Re-runs on a
    /// Jellyfin switch AND when SMB-only home resolves (both move the token) — each step is guarded
    /// so an already-built model isn't rebuilt.
    private func loadFeed() async {
        // tvOS launch gate already fetched the feed — adopt it and skip the
        // redundant load. No gate release here: FocusRootView is the
        // authoritative tvOS release site (it already fired before this mounts).
        if let preloaded {
            session = preloaded.session
            viewModel = preloaded.viewModel
            return
        }
        // No Jellyfin session to feed Home. During bootstrapping this is transient (the source set
        // lands shortly and the token moves, re-firing this task) — hold on the skeleton. But once
        // SMB-only routing reaches `.home` without a Jellyfin session, that's the revealable
        // `HomeUnavailableView` placeholder, so release the launch hold.
        guard router.activeServerID != nil else {
            if router.destination == .home { launchGate.markContentReady() }
            return
        }
        if session == nil {
            session = await deps.serverStore.active
        }
        // The router cached an active server the store can no longer produce a session for — a
        // desync (session cleared elsewhere, or a failed credential/keychain rebuild). `active` is
        // never transiently nil here (it's stable actor state and `load()` is already done), so a
        // nil means the cached id is genuinely stale. Re-sync the router to the store's truth
        // instead of releasing the launch reveal onto an endless skeleton: with no Jellyfin session
        // it falls to SMB-only home if an SMB source remains, else to `.login` (which finishes the
        // launch stage), where the user can re-authenticate.
        guard let session else {
            router.updateForSources(
                activeSession: nil,
                hasAuxiliarySources: await deps.serverStore.hasSMBServers
            )
            return
        }
        if viewModel == nil {
            let repo = await deps.jellyfinLibraryRepoFactory(session)
            viewModel = HomeViewModel(repo: repo, userDataActions: userDataActions)
            await viewModel?.load()
        }
        // Releases the cold-launch sync-hold: `load()` has returned (loaded
        // OR failed — both are revealable screens). One-shot; server-switch
        // re-runs are no-ops inside the gate.
        launchGate.markContentReady()
    }

    /// Discriminates which top-level branch of `content` is showing, for `crossfadeStateSwap`.
    /// Deliberately NOT `vm.state` itself (payload-carrying, not `Hashable`) — both loading
    /// branches (the pre-session bootstrap skeleton and `vm.state`'s own `.idle`/`.loading`)
    /// collapse to the same `.skeleton` case, since they render the identical placeholder.
    private var contentPhase: HomeContentPhase {
        if let vm = viewModel, session != nil {
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
        if let vm = viewModel, let session {
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
                    if !vm.heroFeed.isEmpty {
                        HomeHeroCarousel(
                            entries: vm.heroFeed,
                            session: session,
                            viewModel: vm,
                            scroll: heroScroll
                        )
                    }
                    HomeShelves(viewModel: vm, session: session)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    let session: Session

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
                MetadataRow(title: "Continue Watching", items: vm.continueWatching, tileWidth: AppLayout.shelfTileWidth(idiom: idiom)) { item in
                    homeShelfTile(item: item, showProgress: true)
                }
                .prefetchArtwork(shelfArtworkURLs(vm.continueWatching), session: session)
            }
            if !vm.nextUp.isEmpty {
                MetadataRow(title: "Next Up", items: vm.nextUp, tileWidth: AppLayout.shelfTileWidth(idiom: idiom)) { item in
                    homeShelfTile(item: item, showProgress: false)
                }
                .prefetchArtwork(shelfArtworkURLs(vm.nextUp), session: session)
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

    /// The exact artwork URLs the shelf tiles will request, built with `ArtworkRequest` so the
    /// prefetch warms the SAME cache key the tiles read (any drift = a wasted double-download). Uses
    /// the same ref (`homeShelfImageRef`), ceiling, render width, scale, and aspect as the tile.
    private func shelfArtworkURLs(_ items: [Item]) -> [URL] {
        let size = ArtworkRequest.boxedSize(
            ceiling: HomeShelf.imageMaxWidth,
            renderPointWidth: AppLayout.shelfTileWidth(idiom: idiom),
            displayScale: displayScale,
            aspectRatio: MediaImage.poster
        )
        return items.compactMap { item in
            item.homeShelfImageRef.flatMap {
                ImageURLBuilder.url(serverURL: session.serverURL, ref: $0, maxWidth: size.width, maxHeight: size.height)
            }
        }
    }

    @ViewBuilder
    private func homeShelfTile(item: Item, showProgress: Bool) -> some View {
        // Home is play-first: a movie tile plays (and resumes) immediately instead of opening
        // detail. Episodes already play; series still need detail to pick an episode.
        ItemNavigator(item: item, session: session, movieTap: .plays) {
            MediaThumbnail(
                jellyfin: item.homeShelfImageRef,
                session: session,
                footer: MediaThumbnail.Footer.make(
                    caption: homeShelfCaption(item, showProgress: showProgress),
                    progress: showProgress ? tileProgress(item) : nil
                ),
                aspectRatio: MediaImage.poster,
                maxImageWidth: HomeShelf.imageMaxWidth,
                // Trim the request to the tile's actual point width × display scale (capped at the
                // @3x ceiling), so a 2x panel doesn't decode the full @3x thumb. No visual change.
                maxImageRenderWidth: AppLayout.shelfTileWidth(idiom: idiom),
                accessibilityLabel: item.displayTitle
            )
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

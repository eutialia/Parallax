import SwiftUI
import ParallaxJellyfin

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(LaunchGate.self) private var launchGate
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.appIdiom) private var idiom
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Supplied by the tvOS launch gate (`FocusRootView`), which loads the feed up front so the
    /// hero is on screen — and focusable — the instant the sidebar appears. When set, the view
    /// skips its own fetch. iOS leaves this nil and self-loads in `.task` as before.
    private let preloaded: (session: Session, viewModel: HomeViewModel)?
    @State private var viewModel: HomeViewModel?
    @State private var session: Session?
    @State private var heroScrollAdjustment: CGFloat = 0

    init(preloaded: (session: Session, viewModel: HomeViewModel)? = nil) {
        self.preloaded = preloaded
    }

    var body: some View {
        ScrollView {
            content
        }
        // Feed the hero the SIGNED scroll adjustment: positive = pull-down rubber-band
        // (stretchy zoom), negative = scrolled into the feed (artwork parallax).
        // `contentOffset + contentInsets.top` is 0 at rest regardless of safe-area/
        // nav-bar insets, so this self-calibrates. The negative side is floored at one
        // viewport: past that the hero is off-screen, and pinning the value there stops
        // per-frame state writes (and Home body re-evaluations) for the rest of the feed.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            max(-(geo.contentOffset.y + geo.contentInsets.top), -geo.containerSize.height)
        } action: { _, newValue in
            heroScrollAdjustment = newValue
        }
        .scrollClipDisabled(true)
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
        // tvOS bleeds the hero horizontally too (overscan); the shelves re-inset via
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
        .task(id: router.activeServerID) {
            // tvOS launch gate already fetched the feed — adopt it and skip the
            // redundant load. No gate release here: FocusRootView is the
            // authoritative tvOS release site (it already fired before this mounts).
            if let preloaded {
                session = preloaded.session
                viewModel = preloaded.viewModel
                return
            }
            // Skeleton-only until bootstrap sets `activeServerID` — avoids a fetch that
            // `RootTabView`'s `.id` remount would cancel when the session becomes active.
            guard router.activeServerID != nil else { return }
            if session == nil {
                session = await deps.serverStore.active
            }
            if viewModel == nil, let session {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = HomeViewModel(repo: repo)
                await viewModel?.load()
            }
            // Releases the cold-launch sync-hold: `load()` has returned (loaded
            // OR failed — both are revealable screens). One-shot; server-switch
            // re-runs are no-ops inside the gate.
            launchGate.markContentReady()
        }
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
                LazyVStack(alignment: .leading, spacing: Space.s30) {
                    if !vm.heroFeed.isEmpty {
                        HomeHeroCarousel(
                            entries: vm.heroFeed,
                            session: session,
                            viewModel: vm,
                            scrollAdjustment: heroScrollAdjustment
                        )
                    }
                    // Everything below the full-bleed hero stays inside the tvOS title-safe
                    // region (`tvContentInset()`), so focusable shelf cards aren't clipped by
                    // overscan. No-op on iOS.
                    VStack(alignment: .leading, spacing: Space.s30) {
                        if !vm.continueWatching.isEmpty {
                            MetadataRow(title: "Continue Watching", items: vm.continueWatching, tileWidth: AppLayout.shelfTileWidth(idiom: idiom)) { item in
                                homeShelfTile(item: item, session: session, showProgress: true)
                            }
                        }
                        if !vm.nextUp.isEmpty {
                            MetadataRow(title: "Next Up", items: vm.nextUp, tileWidth: AppLayout.shelfTileWidth(idiom: idiom)) { item in
                                homeShelfTile(item: item, session: session, showProgress: false)
                            }
                        }
                        if vm.heroFeed.isEmpty && vm.continueWatching.isEmpty && vm.nextUp.isEmpty {
                            ContentUnavailableView(
                                "Nothing here yet",
                                systemImage: "play.slash",
                                description: Text("Play something from your library and it will appear here.")
                            )
                            .padding(.top, Space.s60)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tvContentInset()
                    // Dim + crossfade the progress-driven shelves while `refresh()` re-pulls
                    // them after playback — same recipe as the library grid's sort/filter.
                    .staleWhileRevalidate(isRefreshing: vm.isRefreshing, reduceMotion: reduceMotion)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Space.s30)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't load Home",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .padding(.top, Space.s60)
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
        } else {
            HomeLoadingSkeleton()
        }
    }

    // MARK: - Item rendering helpers

    @ViewBuilder
    private func homeShelfTile(item: Item, session: Session, showProgress: Bool) -> some View {
        ItemNavigator(item: item, session: session) {
            MediaTile(
                title: item.displayTitle,
                imageRef: item.homeShelfImageRef,
                imageKind: item.homeShelfImageKind,
                session: session,
                progress: showProgress ? tileProgress(item) : nil,
                progressCaption: homeShelfCaption(item, showProgress: showProgress),
                aspectRatio: JellyfinImage.poster,
                maxImageWidth: HomeShelf.imageMaxWidth
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

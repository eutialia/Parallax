import SwiftUI
import ParallaxJellyfin

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var viewModel: HomeViewModel?
    @State private var session: Session?

    var body: some View {
        ScrollView {
            content
        }
        .scrollClipDisabled(true)
        // Fill the detail width even while the loading state's content is small —
        // otherwise on a cold launch the ScrollView collapses to its content's ideal
        // width (~100pt for the loading spinner) until a later layout pass, showing a
        // narrow strip. Greedy frame pins it to the proposed width from the first pass.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid floor under the scroll content so the floating iPadOS 26
        // sidebar's translucent material blurs over the app background
        // instead of letting tile imagery bleed through.
        .background(Color.background)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Home")
        .toolbar(.hidden, for: .navigationBar)
        .itemZoomNavigation()
        .task(id: router.activeServerID) {
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
                    if !vm.recentlyAdded.isEmpty {
                        HomeHeroCarousel(
                            items: vm.recentlyAdded,
                            session: session,
                            viewModel: vm
                        )
                    }
                    if !vm.continueWatching.isEmpty {
                        MetadataRow(title: "Continue Watching", items: vm.continueWatching, tileWidth: 240) { item in
                            itemTile(item: item, session: session, showProgress: true)
                        }
                    }
                    if !vm.nextUp.isEmpty {
                        MetadataRow(title: "Next Up", items: vm.nextUp, tileWidth: 240) { item in
                            itemTile(item: item, session: session, showProgress: false)
                        }
                    }
                    if vm.recentlyAdded.isEmpty && vm.continueWatching.isEmpty && vm.nextUp.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: "play.slash").padding(.top, Space.s60)
                    }
                }
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
                "Favorite",
                isPresented: $vm.isShowingFavoriteError,
                presenting: vm.favoriteErrorMessage
            ) { _ in
                Button("OK", role: .cancel) { }
            } message: { message in
                Text(message)
            }
        } else {
            HomeLoadingSkeleton()
        }
    }

    @ViewBuilder
    private func landscapeTile(item: Item, session: Session, showProgress: Bool) -> some View {
        MediaTile(
            title: item.displayTitle,
            subtitle: tileSubtitle(item),
            imageRef: item.landscapeImageRef,
            imageKind: item.landscapeImageKind,
            session: session,
            progress: showProgress ? tileProgress(item) : nil,
            aspectRatio: JellyfinImage.landscape,
            maxImageWidth: 600
        )
    }

    // MARK: - Item rendering helpers
    @ViewBuilder
    private func itemTile(item: Item, session: Session, showProgress: Bool) -> some View {
        ItemNavigator(item: item, session: session) {
            landscapeTile(item: item, session: session, showProgress: showProgress)
        }
    }

    private func tileSubtitle(_ item: Item) -> String? {
        switch item {
        // Home rows show only the title for movies/series; episodes get a
        // compact SxxExx so the tile reads "name / S01E04" (smoke-test #7).
        case .movie, .series: return nil
        case .episode(let e): return e.episodeCode
        }
    }

    private func tileProgress(_ item: Item) -> Double? {
        let runtimeTicks: Int64?
        switch item {
        case .movie(let m): runtimeTicks = m.runtime.map { Int64($0.components.seconds) * 10_000_000 }
        case .series: runtimeTicks = nil
        case .episode(let e): runtimeTicks = e.runtime.map { Int64($0.components.seconds) * 10_000_000 }
        }
        return item.userData.playedFraction(runtimeTicks: runtimeTicks)
    }
}

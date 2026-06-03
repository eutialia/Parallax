import SwiftUI
import ParallaxJellyfin

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @State private var viewModel: HomeViewModel?
    @State private var session: Session?

    var body: some View {
        ScrollView {
            content
        }
        // Solid floor under the scroll content so the floating iPadOS 26
        // sidebar's translucent material blurs over the app background
        // instead of letting tile imagery bleed through.
        .background(Color(.systemBackground))
        .navigationTitle("Home")
        .navigationDestination(for: ItemNavigation.self) { nav in
            destinationView(for: nav)
        }
        .task {
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
            switch vm.state {
            case .idle, .loading:
                ProgressView().padding(40)
            case .loaded:
                VStack(alignment: .leading, spacing: 24) {
                    if !vm.continueWatching.isEmpty {
                        MetadataRow(
                            title: "Continue Watching",
                            items: vm.continueWatching,
                            tileWidth: 240
                        ) { item in
                            itemTile(item: item, session: session, showProgress: true)
                        }
                    }
                    if !vm.nextUp.isEmpty {
                        MetadataRow(
                            title: "Next Up",
                            items: vm.nextUp,
                            tileWidth: 240
                        ) { item in
                            itemTile(item: item, session: session, showProgress: false)
                        }
                    }
                    if vm.continueWatching.isEmpty && vm.nextUp.isEmpty {
                        ContentUnavailableView("Nothing to resume", systemImage: "play.slash")
                            .padding(.top, 60)
                    }
                }
                .padding(.vertical)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't load Home",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .padding(.top, 60)
            }
        } else {
            ProgressView().padding(40)
        }
    }

    @ViewBuilder
    private func landscapeTile(item: Item, session: Session, showProgress: Bool) -> some View {
        MediaTile(
            title: tileTitle(item),
            subtitle: tileSubtitle(item),
            imageRef: landscapeImage(item),
            imageKind: landscapeImageKind(item),
            session: session,
            progress: showProgress ? tileProgress(item) : nil,
            aspectRatio: JellyfinImage.landscape,
            maxImageWidth: 600
        )
    }

    @ViewBuilder
    private func destinationView(for nav: ItemNavigation) -> some View {
        switch nav {
        case .movie(let id, let s): MovieDetailView(itemID: id, session: s)
        case .series(let id, let s): SeriesDetailView(itemID: id, session: s)
        case .season(let id, let s): SeasonDetailView(itemID: id, session: s)
        }
    }

    // MARK: - Item rendering helpers
    @ViewBuilder
    private func itemTile(item: Item, session: Session, showProgress: Bool) -> some View {
        switch item {
        case .episode(let e):
            Button { playback.play(e.id, in: session) } label: {
                landscapeTile(item: item, session: session, showProgress: showProgress)
            }
            .buttonStyle(.plain)
        case .movie(let m):
            NavigationLink(value: ItemNavigation.movie(m.id, session)) {
                landscapeTile(item: item, session: session, showProgress: showProgress)
            }
            .buttonStyle(.plain)
        case .series(let s):
            NavigationLink(value: ItemNavigation.series(s.id, session)) {
                landscapeTile(item: item, session: session, showProgress: showProgress)
            }
            .buttonStyle(.plain)
        }
    }

    private func tileTitle(_ item: Item) -> String {
        switch item {
        case .movie(let m): return m.title
        case .series(let s): return s.title
        case .episode(let e): return e.name
        }
    }

    private func tileSubtitle(_ item: Item) -> String? {
        switch item {
        // Home rows show only the title for movies/series; episodes get a
        // compact SxxExx so the tile reads "name / S01E04" (smoke-test #7).
        case .movie, .series: return nil
        case .episode(let e):
            guard let season = e.parentIndexNumber, let idx = e.indexNumber else { return nil }
            return "S\(String(format: "%02d", season))E\(String(format: "%02d", idx))"
        }
    }

    // For landscape Home rows we want 16:9 imagery for every type. Episodes'
    // .primary IS a 16:9 still; movies/series prefer .thumb then .backdrop
    // then fall back to the poster as last resort (still cropped to 16:9 fill).
    private func landscapeImage(_ item: Item) -> ImageRef? {
        switch item {
        case .movie(let m):
            return m.imageRef(.thumb) ?? m.imageRef(.backdrop(index: 0)) ?? m.imageRef(.primary)
        case .series(let s):
            return s.imageRef(.thumb) ?? s.imageRef(.backdrop(index: 0)) ?? s.imageRef(.primary)
        case .episode(let e):
            return e.imageRef(.primary)
        }
    }

    private func landscapeImageKind(_ item: Item) -> ImageKind {
        switch item {
        case .movie(let m):
            if m.imageRef(.thumb) != nil { return .thumb }
            if m.imageRef(.backdrop(index: 0)) != nil { return .backdrop(index: 0) }
            return .primary
        case .series(let s):
            if s.imageRef(.thumb) != nil { return .thumb }
            if s.imageRef(.backdrop(index: 0)) != nil { return .backdrop(index: 0) }
            return .primary
        case .episode: return .primary
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

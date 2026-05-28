import SwiftUI
import ParallaxJellyfin

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: HomeViewModel?
    @State private var session: Session?

    var body: some View {
        ScrollView {
            content
        }
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
                VStack(alignment: .leading, spacing: 20) {
                    if !vm.continueWatching.isEmpty {
                        MetadataRow(
                            title: "Continue Watching",
                            items: vm.continueWatching,
                            tileWidth: 160
                        ) { item in
                            NavigationLink(value: nav(for: item, session: session)) {
                                MediaTile(
                                    title: tileTitle(item),
                                    subtitle: tileSubtitle(item),
                                    imageRef: tileImage(item),
                                    imageKind: tileImageKind(item),
                                    session: session,
                                    progress: tileProgress(item)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !vm.nextUp.isEmpty {
                        MetadataRow(
                            title: "Next Up",
                            items: vm.nextUp,
                            tileWidth: 160
                        ) { item in
                            NavigationLink(value: nav(for: item, session: session)) {
                                MediaTile(
                                    title: tileTitle(item),
                                    subtitle: tileSubtitle(item),
                                    imageRef: tileImage(item),
                                    imageKind: tileImageKind(item),
                                    session: session,
                                    progress: nil
                                )
                            }
                            .buttonStyle(.plain)
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
    private func destinationView(for nav: ItemNavigation) -> some View {
        switch nav {
        case .movie(let id, let s): MovieDetailView(itemID: id, session: s)
        case .series(let id, let s): SeriesDetailView(itemID: id, session: s)
        case .season(let id, let s): SeasonDetailView(itemID: id, session: s)
        case .episode(let id, let s): EpisodeDetailView(itemID: id, session: s)
        }
    }

    // MARK: - Item rendering helpers
    private func nav(for item: Item, session: Session) -> ItemNavigation {
        switch item {
        case .movie(let m): return .movie(m.id, session)
        case .series(let s): return .series(s.id, session)
        case .episode(let e): return .episode(e.id, session)
        }
    }

    private func tileTitle(_ item: Item) -> String {
        switch item {
        case .movie(let m): return m.title
        case .series(let s): return s.title
        case .episode(let e):
            if let season = e.parentIndexNumber, let idx = e.indexNumber {
                return "S\(String(format: "%02d", season))E\(String(format: "%02d", idx)) · \(e.name)"
            }
            return e.name
        }
    }

    private func tileSubtitle(_ item: Item) -> String? {
        switch item {
        case .movie(let m): return m.year.map(String.init)
        case .series(let s): return s.year.map(String.init)
        case .episode: return nil
        }
    }

    private func tileImage(_ item: Item) -> ImageRef? {
        switch item {
        case .movie(let m): return m.imageRef(.primary) ?? m.imageRef(.thumb)
        case .series(let s): return s.imageRef(.primary) ?? s.imageRef(.thumb)
        case .episode(let e): return e.imageRef(.primary)
        }
    }

    private func tileImageKind(_ item: Item) -> ImageKind {
        switch item {
        case .movie, .series: return .primary
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

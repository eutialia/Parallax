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
                            NavigationLink(value: nav(for: item, session: session)) {
                                landscapeTile(item: item, session: session, showProgress: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !vm.nextUp.isEmpty {
                        MetadataRow(
                            title: "Next Up",
                            items: vm.nextUp,
                            tileWidth: 240
                        ) { item in
                            NavigationLink(value: nav(for: item, session: session)) {
                                landscapeTile(item: item, session: session, showProgress: false)
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

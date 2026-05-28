import SwiftUI
import ParallaxJellyfin

struct JellyfinSearchView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: JellyfinSearchViewModel?
    @State private var session: Session?

    var body: some View {
        Group {
            if let vm = viewModel, let session {
                content(vm: vm, session: session)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Search")
        .searchable(text: Binding(
            get: { viewModel?.query ?? "" },
            set: { viewModel?.query = $0 }
        ))
        .navigationDestination(for: ItemNavigation.self) { nav in
            switch nav {
            case .movie(let id, let s): MovieDetailView(itemID: id, session: s)
            case .series(let id, let s): SeriesDetailView(itemID: id, session: s)
            case .season(let id, let s): SeasonDetailView(itemID: id, session: s)
            case .episode(let id, let s): EpisodeDetailView(itemID: id, session: s)
            }
        }
        .task {
            if session == nil {
                session = await deps.serverStore.active
            }
            if viewModel == nil, let session {
                let repo = await deps.libraryRepoFactory(session)
                let vm = JellyfinSearchViewModel(repo: repo)
                vm.start()
                viewModel = vm
            }
        }
        .onDisappear {
            viewModel?.stop()
        }
    }

    @ViewBuilder
    private func content(vm: JellyfinSearchViewModel, session: Session) -> some View {
        switch vm.state {
        case .idle:
            ContentUnavailableView("Search your library", systemImage: "magnifyingglass")
        case .loading:
            ProgressView().padding(40)
        case .loaded(let results):
            if results.movies.isEmpty && results.series.isEmpty && results.episodes.isEmpty {
                ContentUnavailableView.search
            } else {
                List {
                    if !results.movies.isEmpty {
                        Section("Movies") {
                            ForEach(results.movies) { m in
                                NavigationLink(value: ItemNavigation.movie(m.id, session)) {
                                    resultRow(title: m.title, subtitle: m.year.map(String.init), imageRef: m.imageRef(.primary), session: session)
                                }
                            }
                        }
                    }
                    if !results.series.isEmpty {
                        Section("Series") {
                            ForEach(results.series) { s in
                                NavigationLink(value: ItemNavigation.series(s.id, session)) {
                                    resultRow(title: s.title, subtitle: s.year.map(String.init), imageRef: s.imageRef(.primary), session: session)
                                }
                            }
                        }
                    }
                    if !results.episodes.isEmpty {
                        Section("Episodes") {
                            ForEach(results.episodes) { e in
                                NavigationLink(value: ItemNavigation.episode(e.id, session)) {
                                    resultRow(title: e.name, subtitle: episodeSubtitle(e), imageRef: e.imageRef(.primary), session: session)
                                }
                            }
                        }
                    }
                }
            }
        case .failed(let message):
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    @ViewBuilder
    private func resultRow(title: String, subtitle: String?, imageRef: ImageRef?, session: Session) -> some View {
        HStack(spacing: 12) {
            JellyfinImage(ref: imageRef, kind: .primary, session: session, maxWidth: 80)
                .frame(width: 44, height: 66)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func episodeSubtitle(_ e: Episode) -> String? {
        guard let s = e.parentIndexNumber, let ep = e.indexNumber else { return nil }
        return "S\(s)E\(ep)"
    }
}

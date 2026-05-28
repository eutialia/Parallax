import SwiftUI
import ParallaxJellyfin

struct JellyfinLibraryListView: View {
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: JellyfinLibraryListViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    ProgressView().padding(40)
                case .loaded:
                    List(vm.collections) { coll in
                        row(for: coll)
                    }
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load libraries",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationDestination(for: CollectionID.self) { id in
            JellyfinLibraryGridView(collectionID: id, session: session)
        }
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = JellyfinLibraryListViewModel(repo: repo)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private func row(for coll: MediaCollection) -> some View {
        let isBrowsable = isSupported(coll.collectionType)
        if isBrowsable {
            NavigationLink(value: coll.id) {
                rowContent(coll, dim: false)
            }
        } else {
            rowContent(coll, dim: true)
        }
    }

    @ViewBuilder
    private func rowContent(_ coll: MediaCollection, dim: Bool) -> some View {
        HStack(spacing: 12) {
            JellyfinImage(
                ref: coll.imageRef(.primary),
                kind: .primary,
                session: session,
                maxWidth: 80
            )
            .frame(width: 60, height: 90)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(coll.name)
                Text(label(for: coll.collectionType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dim ? 0.5 : 1.0)
    }

    private func isSupported(_ type: CollectionType) -> Bool {
        switch type {
        case .movies, .tvShows: return true
        case .other: return false
        }
    }

    private func label(for type: CollectionType) -> String {
        switch type {
        case .movies: return "Movies"
        case .tvShows: return "TV Shows"
        case .other(let raw): return "Not browsable in v1 (\(raw))"
        }
    }
}

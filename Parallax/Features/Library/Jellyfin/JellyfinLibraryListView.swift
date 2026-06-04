import SwiftUI
import ParallaxJellyfin

struct JellyfinLibraryListView: View {
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var viewModel: JellyfinLibraryListViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    ProgressView().padding(40)
                case .loaded:
                    ScrollView {
                        let cols = hSize == .regular ? 3 : 2
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: Space.s12), count: cols),
                            spacing: Space.s12
                        ) {
                            ForEach(vm.collections.filter { isSupported($0.collectionType) }) { coll in
                                NavigationLink(value: coll) { libraryCard(coll) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(Space.s18)
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
        .navigationDestination(for: MediaCollection.self) { coll in
            JellyfinLibraryGridView(collection: coll, session: session)
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
    private func libraryCard(_ coll: MediaCollection) -> some View {
        ZStack(alignment: .bottomLeading) {
            JellyfinImage(ref: coll.imageRef(.primary), kind: .primary, session: session,
                          maxWidth: 600, aspectRatio: 2.0 / 3.0)
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: icon(for: coll.collectionType))
                        .scaledFont(16, relativeTo: .headline, weight: .semibold).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                Text(coll.name).font(.headline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(Space.s14)
        }
        // Pin the card to a poster aspect so a library with no Primary image (e.g.
        // "Anime") keeps full height instead of collapsing to the text line — which,
        // with the missing contentShape, left only the label tappable.
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.card))
        .contentShape(.rect(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func icon(for type: CollectionType) -> String {
        switch type {
        case .movies: return "film.fill"
        case .tvShows: return "tv.fill"
        case .other: return "folder.fill"
        }
    }

    private func isSupported(_ type: CollectionType) -> Bool {
        switch type {
        case .movies, .tvShows: return true
        case .other: return false
        }
    }
}

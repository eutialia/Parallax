import SwiftUI
import ParallaxJellyfin

struct EpisodeDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: EpisodeDetailViewModel?
    @State private var playerItem: ItemDetail?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    ProgressView().padding(40)
                case .loaded(let ed):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            JellyfinImage(
                                ref: ed.episode.imageRef(.primary),
                                kind: .primary,
                                session: session,
                                maxWidth: 1280,
                                aspectRatio: JellyfinImage.landscape
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                if let s = ed.episode.parentIndexNumber, let e = ed.episode.indexNumber {
                                    Text("Season \(s) · Episode \(e)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(ed.episode.name).font(.title2).bold()
                                if let runtime = ed.episode.runtime {
                                    Text("\(Int(runtime.components.seconds / 60)) min")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 20)

                            Button {
                                playerItem = .episode(ed)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal, 20)

                            if let overview = ed.episode.overview {
                                Text(overview).padding(.horizontal, 20)
                            }
                            if !ed.people.isEmpty {
                                metadataLine(label: "Cast", value: ed.people.prefix(10).joined(separator: ", "))
                            }
                        }
                        .padding(.vertical)
                    }
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load this episode",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .fullScreenCover(item: $playerItem) { detail in
            PlayerView(item: detail, session: session)
        }
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = EpisodeDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private func metadataLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
        .padding(.horizontal, 20)
    }
}

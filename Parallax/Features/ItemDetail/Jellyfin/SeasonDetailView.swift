import SwiftUI
import ParallaxJellyfin

struct SeasonDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @State private var viewModel: SeasonDetailViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    ProgressView().padding(40)
                case .loaded(let sd, let episodes):
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                JellyfinImage(
                                    ref: sd.season.imageRef(.primary),
                                    kind: .primary,
                                    session: session,
                                    maxWidth: 400,
                                    aspectRatio: JellyfinImage.poster
                                )
                                .frame(maxWidth: 200, maxHeight: 300)
                                .clipShape(.rect(cornerRadius: 8))
                                Text(sd.season.name).font(.title2).bold()
                                if let overview = sd.overview {
                                    Text(overview).font(.callout)
                                }
                            }
                        }
                        Section("Episodes") {
                            ForEach(episodes) { ep in
                                Button { playback.play(ep.id, in: session) } label: {
                                    episodeRow(ep)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load this season",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = SeasonDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private func episodeRow(_ ep: Episode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            JellyfinImage(
                ref: ep.imageRef(.primary),
                kind: .primary,
                session: session,
                maxWidth: 320,
                aspectRatio: JellyfinImage.landscape
            )
            .frame(width: 120, height: 68)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                if let n = ep.indexNumber {
                    Text("Episode \(n)").font(.caption).foregroundStyle(.secondary)
                }
                Text(ep.name).font(.body).lineLimit(2)
                if let runtime = ep.runtime {
                    Text("\(Int(runtime.components.seconds / 60)) min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

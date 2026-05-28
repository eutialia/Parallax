import SwiftUI
import ParallaxJellyfin

struct SeriesDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: SeriesDetailViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    ProgressView().padding(40)
                case .loaded(let sd, let seasons):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            DetailHeader(
                                title: sd.series.title,
                                subtitle: subtitle(sd),
                                backdropRef: sd.series.imageRef(.backdrop(index: 0)),
                                logoRef: sd.series.imageRef(.logo),
                                session: session
                            )
                            if let overview = sd.series.overview {
                                Text(overview).padding(.horizontal, 20)
                            }
                            if !seasons.isEmpty {
                                MetadataRow(title: "Seasons", items: seasons, tileWidth: 140) { season in
                                    NavigationLink(value: ItemNavigation.season(season.id, session)) {
                                        MediaTile(
                                            title: season.name,
                                            subtitle: season.episodeCount.map { "\($0) episodes" },
                                            imageRef: season.imageRef(.primary),
                                            imageKind: .primary,
                                            session: session,
                                            progress: nil
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if !sd.series.genres.isEmpty {
                                metadataLine(label: "Genres", value: sd.series.genres.joined(separator: ", "))
                            }
                        }
                        .padding(.vertical)
                    }
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load this series",
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
                viewModel = SeriesDetailViewModel(repo: repo, itemID: itemID)
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

    private func subtitle(_ sd: SeriesDetail) -> String? {
        var parts: [String] = []
        if let y = sd.series.year { parts.append(String(y)) }
        if let s = sd.series.status { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

import SwiftUI
import ParallaxJellyfin

struct SeriesDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @State private var viewModel: SeriesDetailViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    ProgressView().padding(40)
                case .loaded(let sd, let seasons):
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s22) {
                            DetailHeader(
                                title: sd.series.title,
                                subtitle: subtitle(sd),
                                backdropRef: sd.series.imageRef(.backdrop(index: 0)),
                                session: session
                            )
                            if let overview = sd.series.overview {
                                Text(overview).padding(.horizontal, Space.s18)
                            }
                            if !seasons.isEmpty {
                                seasonPicker(seasons: seasons, vm: vm)
                                    .padding(.horizontal, Space.s18)
                            }
                            episodeList(vm: vm)
                            if !sd.series.genres.isEmpty {
                                metadataLine(label: "Genres", value: sd.series.genres.joined(separator: ", "))
                            }
                        }
                        .padding(.vertical)
                    }
                case .failed(let message):
                    ContentUnavailableView("Couldn't load this series", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = SeriesDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private func seasonPicker(seasons: [Season], vm: SeriesDetailViewModel) -> some View {
        let current = seasons.first { $0.id == vm.selectedSeasonID } ?? seasons.first
        Menu {
            ForEach(seasons) { season in
                Button(season.name) { Task { await vm.selectSeason(season.id) } }
            }
        } label: {
            HStack(spacing: Space.s8) {
                Text(current?.name ?? "Season").font(.headline).foregroundStyle(Color.label)
                Image(systemName: "chevron.down").font(.subheadline).foregroundStyle(Color.secondaryLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s14).frame(height: 44)
            .glassPanel(cornerRadius: Radius.field)
        }
    }

    @ViewBuilder
    private func episodeList(vm: SeriesDetailViewModel) -> some View {
        if vm.episodesLoading {
            ProgressView().padding(.vertical, Space.s22).frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(vm.episodes) { ep in
                    Button { playback.play(ep.id, in: session) } label: {
                        episodeRow(ep)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func episodeRow(_ ep: Episode) -> some View {
        HStack(alignment: .top, spacing: Space.s12) {
            JellyfinImage(ref: ep.imageRef(.primary), kind: .primary, session: session, maxWidth: 320, aspectRatio: JellyfinImage.landscape)
                .frame(width: 120, height: 68)
                .clipShape(.rect(cornerRadius: Radius.tile))
            VStack(alignment: .leading, spacing: 4) {
                if let n = ep.indexNumber {
                    Text("Episode \(n)").font(.caption).foregroundStyle(Color.secondaryLabel)
                }
                Text(ep.name).font(.body).foregroundStyle(Color.label).lineLimit(2)
                if let runtime = ep.runtime {
                    Text("\(Int(runtime.components.seconds / 60)) min").font(.caption2).foregroundStyle(Color.secondaryLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s18).padding(.vertical, Space.s8)
    }

    @ViewBuilder
    private func metadataLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Color.secondaryLabel)
            Text(value).font(.callout).foregroundStyle(Color.label)
        }
        .padding(.horizontal, Space.s18)
    }

    private func subtitle(_ sd: SeriesDetail) -> String? {
        var parts: [String] = []
        if let y = sd.series.year { parts.append(String(y)) }
        if let s = sd.series.status { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

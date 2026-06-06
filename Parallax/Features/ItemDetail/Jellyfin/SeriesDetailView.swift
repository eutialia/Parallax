import SwiftUI
import ParallaxJellyfin

struct SeriesDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var viewModel: SeriesDetailViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    DetailLoadingSkeleton()
                case .loaded(let sd, let seasons):
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s22) {
                            HeroBackdrop {
                                HeroBandImage(
                                    landscapeRef: sd.series.imageRef(.backdrop(index: 0)),
                                    posterRef: sd.series.imageRef(.primary),
                                    session: session,
                                    regularWidth: hSize == .regular
                                )
                            } foreground: {
                                VStack(alignment: .leading, spacing: Space.s12) {
                                    Text(sd.series.title)
                                        .scaledFont(hSize == .regular ? 48 : 30, relativeTo: .largeTitle, weight: .heavy)
                                        .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                                    if let sub = subtitle(sd) {
                                        Text(sub).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                                    }
                                    HStack(spacing: Space.s12) {
                                        if let ep = vm.resumeEpisode {
                                            PrimaryPlayButton(
                                                title: resumeLabel(ep),
                                                fillWidth: false,
                                                layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle
                                            ) {
                                                playback.play(ep.id, in: session)
                                            }
                                        }
                                        FavoriteActionButton(isFavorite: vm.isFavorite) {
                                            Task { await vm.toggleFavorite() }
                                        }
                                    }
                                    .padding(.top, Space.s8)
                                }
                            }

                            if let overview = sd.series.overview {
                                Text(overview).padding(.horizontal, Space.s18)
                            }
                            if !seasons.isEmpty {
                                seasonPicker(seasons: seasons, vm: vm)
                                    .padding(.horizontal, Space.s18)
                                DetailActionButton(systemImage: "checkmark.circle", label: "Mark Season Watched") {
                                    Task { await vm.markSelectedSeasonWatched() }
                                }
                                .padding(.horizontal, Space.s18)
                            }
                            episodeList(vm: vm)
                            if !sd.series.genres.isEmpty {
                                DetailMetadataLine(label: "Genres", value: sd.series.genres.joined(separator: ", "))
                            }
                        }
                        .padding(.bottom, Space.s30)
                    }
                    .scrollClipDisabled(true)
                    .scrollEdgeEffectHidden(true, for: .top)
                case .failed(let message):
                    ContentUnavailableView("Couldn't load this series", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            } else {
                DetailLoadingSkeleton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
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
            }
            .padding(.horizontal, Space.s14)
            // Explicit full width (not a trailing Spacer) so the Menu doesn't
            // re-measure the label to its intrinsic size and snap it to the right
            // edge when it opens.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .glassPanel(cornerRadius: Radius.field)
        }
    }

    @ViewBuilder
    private func episodeList(vm: SeriesDetailViewModel) -> some View {
        if vm.episodesLoading {
            EpisodeListLoadingSkeleton()
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

    private func subtitle(_ sd: SeriesDetail) -> String? {
        var parts: [String] = []
        if let y = sd.series.year { parts.append(String(y)) }
        if let s = sd.series.status { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resumeLabel(_ ep: Episode) -> String {
        if let s = ep.parentIndexNumber, let e = ep.indexNumber { return "Resume S\(s) E\(e)" }
        return "Resume"
    }
}

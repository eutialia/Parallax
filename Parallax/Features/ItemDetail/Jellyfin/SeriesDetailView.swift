import SwiftUI
import ParallaxJellyfin

struct SeriesDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
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
                                    regularWidth: idiom.usesLandscapeHeroBand
                                )
                            } foreground: {
                                VStack(alignment: .leading, spacing: Space.s12) {
                                    HeroTitle(
                                        item: .series(sd.series),
                                        session: session,
                                        regularWidth: idiom.usesLandscapeHeroBand,
                                        scale: .detail
                                    )
                                    let meta = DetailMetadata(series: sd.series)
                                    if !meta.isEmpty {
                                        DetailHeroMetadataRow(metadata: meta)
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
                                            .tvChipButton()
                                        }
                                        FavoriteActionButton(isFavorite: vm.isFavorite) {
                                            Task { await vm.toggleFavorite() }
                                        }
                                        .tvChipButton()
                                    }
                                    .padding(.top, Space.s8)
                                }
                            }

                            if let overview = sd.series.overview {
                                DetailOverview(text: overview)
                                    .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                            }
                            seasonEpisodeShelves(seasons: seasons, vm: vm)
                            if !sd.series.genres.isEmpty {
                                DetailMetadataLine(label: "Genres", value: sd.series.genres.joined(separator: ", "))
                            }
                        }
                        .padding(.bottom, Space.s30)
                    }
                    .scrollClipDisabled(true)
                    #if !os(tvOS)
                    .scrollEdgeEffectHidden(true, for: .top)
                    #endif
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
    private func seasonEpisodeShelves(seasons: [Season], vm: SeriesDetailViewModel) -> some View {
        if vm.episodesLoading {
            EpisodeListLoadingSkeleton()
        } else {
            VStack(alignment: .leading, spacing: Space.s22) {
                ForEach(seasons) { season in
                    let episodes = vm.episodes(for: season.id)
                    if !episodes.isEmpty {
                        MetadataRow(
                            title: season.name,
                            items: episodes,
                            tileWidth: AppLayout.seriesEpisodeTileWidth(idiom: idiom)
                        ) { episode in
                            Button {
                                playback.play(episode.id, in: session)
                            } label: {
                                episodeCard(episode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func episodeCard(_ episode: Episode) -> some View {
        MediaTile(
            title: episode.name,
            imageRef: episode.imageRef(.primary),
            imageKind: .primary,
            session: session,
            progress: episode.shelfPlaybackProgress,
            progressCaption: episode.shelfFooterCaption(),
            aspectRatio: JellyfinImage.landscape,
            maxImageWidth: SeriesShelf.imageMaxWidth
        )
    }

    private func resumeLabel(_ ep: Episode) -> String {
        if let s = ep.parentIndexNumber, let e = ep.indexNumber { return "Resume S\(s) E\(e)" }
        return "Resume"
    }
}

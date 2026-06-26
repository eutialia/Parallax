import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct SeriesDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            HeroBand {
                                HeroBandImage(
                                    landscapeRef: sd.series.imageRef(.backdrop(index: 0)),
                                    posterRef: sd.series.imageRef(.primary),
                                    session: session,
                                    regularWidth: idiom.usesLandscapeHeroBand
                                )
                            } foreground: {
                                HeroForeground(
                                    eyebrow: nil,
                                    title: HeroTitle(
                                        item: .series(sd.series),
                                        session: session,
                                        regularWidth: idiom.usesLandscapeHeroBand,
                                        scale: .detail
                                    )
                                ) {
                                    let meta = DetailMetadata(series: sd.series)
                                    if !meta.isEmpty {
                                        DetailHeroMetadataRow(metadata: meta)
                                    }
                                } actions: {
                                    // Play never disappears: a fully-watched series gets no
                                    // /Shows/NextUp episode (Jellyfin treats finished — and empty —
                                    // series as watched), so the row falls back to the first episode.
                                    // Mid-series adds the prominent Resume beside a from-the-beginning Play.
                                    let resume = vm.resumeEpisode
                                    let showsResume = resume.map(ItemPlayButtonLabel.shouldResumeSeries) ?? false
                                    if showsResume, let ep = resume {
                                        PrimaryPlayButton(
                                            title: resumeLabel(ep),
                                            fillWidth: false,
                                            layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle
                                        ) {
                                            playback.play(ep.id, in: session)
                                        }
                                    } else if let target = resume ?? vm.firstEpisode {
                                        PrimaryPlayButton(
                                            title: "Play",
                                            fillWidth: false,
                                            layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle
                                        ) {
                                            playback.play(target.id, in: session)
                                        }
                                    }
                                    FavoriteActionButton(isFavorite: vm.isFavorite) {
                                        Task { await vm.toggleFavorite() }
                                    }
                                }
                            }
                            .heroBandFrame(regularWidth: idiom.usesLandscapeHeroBand)

                            // Overview + genres fold into one tappable info section (full card on
                            // tap); the season shelves stay below it. The section is focusable, so
                            // even a series with NO season shelf has a tvOS scroll target. Body +
                            // shelves stay inside the tvOS title-safe region while the hero bleeds.
                            let info = DetailInfo(series: sd)
                            VStack(alignment: .leading, spacing: Space.s22) {
                                if info.hasContent {
                                    DetailInfoSection(info: info)
                                }
                                seasonEpisodeShelves(seasons: seasons, vm: vm)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tvContentInset()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Space.s30)
                        // Dim + crossfade the page while `refresh()` re-pulls progress after
                        // playback, so the episode progress bars / watched checks and the Resume
                        // target swap under the dim instead of snapping — same recipe as Home's
                        // shelves. tvOS swaps instantly (no crossfade); see the modifier.
                        .staleWhileRevalidate(isRefreshing: vm.isRefreshing, reduceMotion: reduceMotion)
                    }
                    .scrollClipDisabled(true)
                    #if !os(tvOS)
                    .scrollEdgeEffectHidden(true, for: .top)
                    #endif
                case .failed(let message):
                    StatusStateView.failure("Couldn't load this series", message: message)
                }
            } else {
                DetailLoadingSkeleton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .heroScreenSafeArea()
        .screenFloor()
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            if viewModel == nil {
                let repo = await deps.jellyfinLibraryRepoFactory(session)
                viewModel = SeriesDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
        // A finished playback session moved an episode's position (incl. prev/next jumps),
        // so re-pull the series the moment the player dismisses. The view stays MOUNTED
        // under the player layer/cover, so `.task` never re-fires — `playback.request`
        // clearing (id → nil) is the only "back from watching" edge. Mirrors HomeView.
        .onChange(of: playback.request?.id) { oldID, newID in
            if oldID != nil, newID == nil {
                Task { await viewModel?.refresh() }
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
                            // Bare button — `MetadataRow` applies `.tvShelfItem()` (native
                            // `.borderless` lockup on tvOS / `.plain` on iOS) to every item,
                            // so it focuses like the poster cards. A local `.buttonStyle`
                            // here would override that.
                            Button {
                                playback.play(episode.id, in: session)
                            } label: {
                                episodeCard(episode)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func episodeCard(_ episode: Episode) -> some View {
        MediaThumbnail(
            jellyfin: episode.imageRef(.primary),
            session: session,
            // Check only — the footer bar below already carries partial
            // progress, so a ring would say the same thing twice.
            watched: episode.userData.played ? .watched : .none,
            footer: MediaThumbnail.Footer.make(
                caption: episode.shelfFooterCaption(),
                progress: episode.shelfPlaybackProgress
            ),
            aspectRatio: MediaImage.landscape,
            maxImageWidth: SeriesShelf.imageMaxWidth,
            // Trim the request to the tile's actual point width × display scale (capped at the @3x
            // ceiling), so a 2x panel doesn't decode the full @3x thumb. No visual change.
            maxImageRenderWidth: AppLayout.seriesEpisodeTileWidth(idiom: idiom),
            accessibilityLabel: episode.name
        )
    }

    private func resumeLabel(_ ep: Episode) -> String {
        if let s = ep.parentIndexNumber, let e = ep.indexNumber { return "Resume S\(s) E\(e)" }
        return "Resume"
    }
}

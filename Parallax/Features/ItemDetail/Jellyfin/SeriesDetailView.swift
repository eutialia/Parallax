import SwiftUI
import ParallaxJellyfin
import ParallaxCore

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
                                    // Play never disappears: a fully-watched series gets
                                    // no /Shows/NextUp episode (Jellyfin treats finished —
                                    // and empty — series as watched), so the row falls back
                                    // to the first episode. Mid-series adds the prominent
                                    // Resume beside a from-the-beginning Play.
                                    HStack(spacing: Space.s12) {
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
                                            // From-the-beginning sibling — hidden when the
                                            // resume target IS the first episode (one button,
                                            // one meaning).
                                            if let first = vm.firstEpisode, first.id != ep.id {
                                                CircleGlassButton(
                                                    systemImage: "play",
                                                    accessibilityLabel: "Play from beginning"
                                                ) {
                                                    playback.play(first.id, in: session)
                                                }
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
                                    // No `GlassEffectContainer` — it misrenders member glass on
                                    // both platforms (see MovieDetailView / "Action row parity").
                                    .padding(.top, Space.s8)
                                    // One focus group so the action row is a coherent focus
                                    // target (Resume default) on tvOS.
                                    .tvFocusSection()
                                }
                            }

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
        MediaTile(
            title: episode.name,
            imageRef: episode.imageRef(.primary),
            imageKind: .primary,
            session: session,
            progress: episode.shelfPlaybackProgress,
            progressCaption: episode.shelfFooterCaption(),
            // Check only — the footer bar above already carries partial
            // progress, so a ring would say the same thing twice.
            watched: episode.userData.played ? .watched : .none,
            aspectRatio: JellyfinImage.landscape,
            maxImageWidth: SeriesShelf.imageMaxWidth
        )
    }

    private func resumeLabel(_ ep: Episode) -> String {
        if let s = ep.parentIndexNumber, let e = ep.indexNumber { return "Resume S\(s) E\(e)" }
        return "Resume"
    }
}

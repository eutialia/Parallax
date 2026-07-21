import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct SeriesDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(UserDataActions.self) private var userDataActions
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var viewModel: SeriesDetailViewModel?
    // The hero band's stretch + parallax channel — same wiring as Home (see `heroScrollChannel`).
    @State private var heroScroll = HeroScrollState()

    /// `crossfadeStateSwap`'s discriminator for `body`'s Group. Only `vm.state`'s own case, not
    /// `vm.isRefreshing`/`vm.episodesLoading` — a post-playback refresh keeps `.loaded` throughout,
    /// so it can't compound with the page's own `staleWhileRevalidate` dim (or the season-shelves'
    /// own inline episode skeleton, which is a deeper, un-crossfaded swap by design).
    private var contentPhase: DetailContentPhase {
        guard let vm = viewModel else { return .skeleton }
        switch vm.state {
        case .idle, .loading: return .skeleton
        case .loaded: return .loaded
        case .failed: return .failed
        }
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    DetailLoadingSkeleton()
                case .loaded(let sd, let seasons):
                    ScrollView {
                        // Band→ledger gap is the shared clearance token: the floor bleed washes
                        // artwork color down here, so the first text line needs more air than a
                        // plain section gap (see `HeroMetrics.floorTextClearance`).
                        VStack(alignment: .leading, spacing: HeroMetrics.floorTextClearance(idiom: idiom)) {
                            let heroImage = HeroBandImage(
                                landscapeRef: sd.series.imageRef(.backdrop(index: 0)),
                                posterRef: sd.series.imageRef(.primary),
                                session: session,
                                regularWidth: idiom.usesLandscapeHeroBand
                            )
                            HeroBand(scroll: heroScroll, floorBleedHash: heroImage.displayedRef?.blurHash) {
                                heroImage
                            } foreground: {
                                HeroForeground(
                                    eyebrow: nil,
                                    title: HeroTitle(
                                        item: .series(sd.series),
                                        session: session,
                                        idiom: idiom,
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

                            // Overview + genres render as the open ledger straight on the floor;
                            // the season shelves stay below it. The overview block is focusable, so
                            // even a series with NO season shelf has a tvOS scroll target. Body +
                            // shelves stay inside the tvOS title-safe region while the hero bleeds.
                            let info = DetailInfo(series: sd)
                            VStack(alignment: .leading, spacing: Space.s22) {
                                if info.hasContent {
                                    DetailMetadataSection(info: info)
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
                    .heroScrollChannel(heroScroll)
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
        // iOS-only crossfade of the whole skeleton→loaded/failed swap; see `crossfadeStateSwap`.
        // Applied here, INSIDE the chrome modifiers below, so those stay on a stable outer node —
        // a phase flip must not re-fire the `.task` below or touch the pushed container's own
        // identity (this view sits under a `.navigationTransition(.zoom)` from `ItemNavigation+View`,
        // applied further out still). tvOS hard-cuts as before.
        .crossfadeStateSwap(contentPhase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .heroScreenSafeArea()
        .screenFloor()
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            if viewModel == nil {
                let repo = await deps.jellyfinLibraryRepoFactory(session)
                viewModel = SeriesDetailViewModel(repo: repo, itemID: itemID, userDataActions: userDataActions)
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
        // Auto-recover the error screen when the network returns (or the app foregrounds online).
        // Gated on `isStalled` so a loaded series is never re-pulled.
        .recoversFromOffline(isStalled: viewModel?.isStalled ?? false) { await viewModel?.load() }
    }

    @ViewBuilder
    private func seasonEpisodeShelves(seasons: [Season], vm: SeriesDetailViewModel) -> some View {
        if vm.episodesLoading {
            EpisodeListLoadingSkeleton()
        } else {
            // Hybrid eager/lazy: an eager stack over EVERY season built each shelf's ScrollView +
            // focus section up front, and the page's frame rate fell off linearly with season count
            // (device-reported at >5-6 seasons, tvOS Release). But a fully lazy stack risks Home's
            // device-verified focus trap (see `HomeView.content`): below-the-fold rows are never
            // materialized, so tvOS focus has nothing to move DOWN to. Splitting the difference —
            // shelf #1 eager (a guaranteed focus target under the hero/ledger), the rest lazy —
            // keeps focus reachable while deferring the expensive shelves: by the time shelf N is
            // focused on the ~⅓-viewport-tall rows, shelf N+1 is inside the lazy render window.
            let populated = seasons.filter { !vm.episodes(for: $0.id).isEmpty }
            VStack(alignment: .leading, spacing: Space.s22) {
                if let first = populated.first {
                    seasonShelf(first, vm: vm, warmsArtwork: true)
                }
                LazyVStack(alignment: .leading, spacing: Space.s22) {
                    ForEach(populated.dropFirst()) { season in
                        seasonShelf(season, vm: vm, warmsArtwork: false)
                    }
                }
            }
        }
    }

    /// One season's horizontal episode shelf. `warmsArtwork` prefetches the FIRST season's stills
    /// only — the shelf visible on open, matching Home's fixed-shelf scope; an unconditional
    /// per-shelf prefetch would fire for every materialized season at once on detail open
    /// (10 seasons ≈ 130 simultaneous requests contending with the hero + the visible shelf).
    /// Later seasons load on demand as their tiles appear.
    @ViewBuilder
    private func seasonShelf(_ season: Season, vm: SeriesDetailViewModel, warmsArtwork: Bool) -> some View {
        let episodes = vm.episodes(for: season.id)
        MetadataRow(
            title: season.name,
            items: episodes,
            tileWidth: AppLayout.seriesEpisodeTileWidth(idiom: idiom)
        ) { episode in
            // `MetadataRow` applies `.tvShelfItem()` (native `.borderless` lockup on
            // tvOS) to every item, so the inner style below only needs to win on iOS —
            // `pressableTileButton()` forwards to the same `tvPosterButton()` on tvOS
            // (byte-identical focus/lockup there) while giving this tile the same
            // touch-down press scale as its closest visual sibling, Home's Continue
            // Watching shelf.
            Button {
                playback.play(episode.id, in: session)
            } label: {
                // `.lockup()`: sibling label children on tvOS so the below-tile title
                // nudges clear of the focus lift (contained on iOS) — the metadata row
                // now under the tile makes this necessary (a bare thumbnail didn't).
                episodeCard(episode).lockup()
            }
            .pressableTileButton()
            // Menu A′: same as the play-first episode menu elsewhere, minus "Go to
            // Series" (this IS that series' page). The VM already subscribes to
            // change events, so badges/progress react without extra wiring.
            .mediaTileContextMenu(
                item: .episode(episode),
                session: session,
                context: MediaTileMenuContext(showsGoToSeries: false)
            )
        }
        .prefetchArtwork(warmsArtwork ? episodeArtworkURLs(episodes) : [], session: session)
    }

    /// The exact artwork URLs this season shelf's episode tiles will request — the same ref
    /// (`imageRef(.primary)`), ceiling, render width, scale, and landscape aspect the tile feeds
    /// `MediaImage`, via the shared `ArtworkPrefetch.urls` so the warm-up hits the tiles' cache key.
    private func episodeArtworkURLs(_ episodes: [Episode]) -> [URL] {
        ArtworkPrefetch.urls(
            for: episodes,
            imageRef: { $0.imageRef(.primary) },
            serverURL: session.serverURL,
            ceiling: SeriesShelf.imageMaxWidth,
            renderPointWidth: AppLayout.seriesEpisodeTileWidth(idiom: idiom),
            displayScale: displayScale,
            aspectRatio: MediaImage.landscape
        )
    }

    /// A season-row episode tile. The one-text-region law puts the identity text BELOW the artwork
    /// (the indexed episode title on line one, time on line two) with only a bar-only progress band
    /// on the image — a same-series surface can afford the episode name a bare shelf caption can't.
    /// Returns `MediaTile` (not `some View`) so the call site can wrap it in `.lockup()` for tvOS.
    private func episodeCard(_ episode: Episode) -> MediaTile {
        MediaTile(
            title: episode.indexedNameCaption,
            imageRef: episode.imageRef(.primary),
            session: session,
            // Check only — the footer bar already carries partial progress, so a ring would say the
            // same thing twice.
            watched: episode.userData.played ? .watched : .none,
            aspectRatio: MediaImage.landscape,
            maxImageWidth: SeriesShelf.imageMaxWidth,
            // Trim the request to the tile's actual point width × display scale (capped at the @3x
            // ceiling), so a 2x panel doesn't decode the full @3x thumb. No visual change.
            maxImageRenderWidth: AppLayout.seriesEpisodeTileWidth(idiom: idiom),
            // Bar-only footer per the law — the caption moved to the metadata row below.
            footer: MediaThumbnail.Footer.make(caption: nil, progress: episode.shelfPlaybackProgress),
            // Time left-aligned under the title: "22 min left" mid-watch, else the full runtime.
            metadata: .init(leading: episode.timeCaption(), trailing: nil)
        )
    }

    private func resumeLabel(_ ep: Episode) -> String {
        if let s = ep.parentIndexNumber, let e = ep.indexNumber { return "Resume S\(s) E\(e)" }
        return "Resume"
    }
}

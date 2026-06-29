import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct MovieDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: MovieDetailViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    DetailLoadingSkeleton()
                case .loaded(let md):
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s18) {
                            HeroBand {
                                HeroBandImage(
                                    landscapeRef: md.movie.imageRef(.backdrop(index: 0)),
                                    posterRef: md.movie.imageRef(.primary),
                                    session: session,
                                    regularWidth: idiom.usesLandscapeHeroBand
                                )
                            } foreground: {
                                HeroForeground(
                                    eyebrow: nil,
                                    title: HeroTitle(
                                        item: .movie(md.movie),
                                        session: session,
                                        regularWidth: idiom.usesLandscapeHeroBand,
                                        scale: .detail
                                    )
                                ) {
                                    let meta = DetailMetadata(movie: md.movie)
                                    if !meta.isEmpty {
                                        DetailHeroMetadataRow(metadata: meta)
                                    }
                                } actions: {
                                    // "Resume" when the movie is mid-watch — the player already
                                    // resumes from the saved position; the pill just never admitted it.
                                    PrimaryPlayButton(
                                        title: ItemPlayButtonLabel.title(for: .movie(md.movie), resumeEpisode: nil),
                                        fillWidth: false,
                                        layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle
                                    ) {
                                        playback.play(.movie(md), in: session)
                                    }
                                    FavoriteActionButton(isFavorite: vm.isFavorite) {
                                        Task { await vm.toggleFavorite() }
                                    }
                                    CircleGlassButton(
                                        systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                                        accessibilityLabel: vm.isPlayed ? "Watched" : "Mark Watched"
                                    ) { Task { await vm.togglePlayed() } }
                                }
                            }
                            .heroBandFrame(regularWidth: idiom.usesLandscapeHeroBand)

                            // Overview + all metadata fold into one tappable info section that
                            // opens the full card — and gives tvOS a focusable target below the
                            // action row so the page scrolls (see `DetailInfoSection`). Stays
                            // inside the tvOS title-safe region while the hero bleeds full-width.
                            let info = DetailInfo(movie: md)
                            if info.hasContent {
                                DetailInfoSection(info: info)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .tvContentInset()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Space.s30)
                        // Dim + crossfade the page while `refresh()` re-pulls progress after
                        // playback, so the Resume label / watched check swap under the dim
                        // instead of snapping — same recipe as Home's shelves.
                        .staleWhileRevalidate(isRefreshing: vm.isRefreshing, reduceMotion: reduceMotion)
                    }
                    .scrollClipDisabled(true)
                    #if !os(tvOS)
                    .scrollEdgeEffectHidden(true, for: .top)
                    #endif
                case .failed(let message):
                    StatusStateView.failure("Couldn't load this title", message: message)
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
                viewModel = MovieDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
        // A finished playback session moved this movie's position, so re-pull it the
        // moment the player dismisses. The view stays MOUNTED under the player layer/
        // cover, so `.task` never re-fires — `playback.request` clearing (id → nil) is
        // the only "back from watching" edge. Mirrors HomeView.
        .onChange(of: playback.request?.id) { oldID, newID in
            if oldID != nil, newID == nil {
                Task { await viewModel?.refresh() }
            }
        }
        // Auto-recover the error screen when the network returns (or the app foregrounds online).
        // Gated on `isStalled` so a loaded title is never re-pulled.
        .recoversFromOffline(isStalled: viewModel?.isStalled ?? false) { await viewModel?.load() }
    }

}

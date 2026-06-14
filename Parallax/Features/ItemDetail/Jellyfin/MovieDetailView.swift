import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct MovieDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
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
                            HeroBackdrop {
                                HeroBandImage(
                                    landscapeRef: md.movie.imageRef(.backdrop(index: 0)),
                                    posterRef: md.movie.imageRef(.primary),
                                    session: session,
                                    regularWidth: idiom.usesLandscapeHeroBand
                                )
                            } foreground: {
                                VStack(alignment: .leading, spacing: Space.s12) {
                                    HeroTitle(
                                        item: .movie(md.movie),
                                        session: session,
                                        regularWidth: idiom.usesLandscapeHeroBand,
                                        scale: .detail
                                    )
                                    let meta = DetailMetadata(movie: md.movie)
                                    if !meta.isEmpty {
                                        DetailHeroMetadataRow(metadata: meta)
                                    }
                                    HStack(spacing: Space.s12) {
                                        // "Resume" when the movie is mid-watch — the player
                                        // already resumes from the saved position; the pill
                                        // just never admitted it.
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
                                    // No `GlassEffectContainer`: it re-renders member glass in its
                                    // own layer, which nudged glyphs off the discs (tvOS), desynced
                                    // from the focus lift, and gray-washed the iOS frost — all
                                    // pixel-measured in the "Action row parity" preview. The native
                                    // buttons never sit close enough to want the blend anyway.
                                    .padding(.top, Space.s8)
                                    // One focus group so the focus engine prefers the action row
                                    // as a unit (Play default) over scattered geometry hits.
                                    .tvFocusSection()
                                }
                            }

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
                    }
                    .scrollClipDisabled(true)
                    #if !os(tvOS)
                    .scrollEdgeEffectHidden(true, for: .top)
                    #endif
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load this title",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
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
                let repo = await deps.libraryRepoFactory(session)
                viewModel = MovieDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
    }

}

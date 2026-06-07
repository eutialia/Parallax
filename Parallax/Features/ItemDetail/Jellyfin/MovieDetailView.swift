import SwiftUI
import ParallaxJellyfin

struct MovieDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(\.appIdiom) private var idiom
    @State private var viewModel: MovieDetailViewModel?
    @State private var playerItem: ItemDetail?

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
                                        PrimaryPlayButton(
                                            title: "Play",
                                            fillWidth: false,
                                            layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle
                                        ) {
                                            playerItem = .movie(md)
                                        }
                                        .tvChipButton()
                                        FavoriteActionButton(isFavorite: vm.isFavorite) {
                                            Task { await vm.toggleFavorite() }
                                        }
                                        .tvChipButton()
                                        CircleGlassButton(
                                            systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                                            isActive: vm.isPlayed,
                                            accessibilityLabel: vm.isPlayed ? "Watched" : "Mark Watched"
                                        ) { Task { await vm.togglePlayed() } }
                                        .tvChipButton()
                                    }
                                    .padding(.top, Space.s8)
                                }
                            }

                            if let tagline = md.tagline {
                                Text(tagline)
                                    .italic()
                                    .foregroundStyle(Color.secondaryLabel)
                                    .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                            }
                            if let overview = md.movie.overview {
                                DetailOverview(text: overview)
                                    .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
                            }
                            if !md.studios.isEmpty {
                                DetailMetadataLine(label: "Studios", value: md.studios.joined(separator: ", "))
                            }
                            if !md.people.isEmpty {
                                DetailMetadataLine(label: "Cast & Crew", value: md.people.prefix(10).joined(separator: ", "))
                            }
                            if !md.movie.genres.isEmpty {
                                DetailMetadataLine(label: "Genres", value: md.movie.genres.joined(separator: ", "))
                            }
                        }
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
        .ignoresSafeArea(edges: .top)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .fullScreenCover(item: $playerItem) { detail in
            PlayerView(item: detail, session: session)
        }
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = MovieDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
    }

}

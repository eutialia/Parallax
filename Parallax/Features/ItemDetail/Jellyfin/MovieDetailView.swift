import SwiftUI
import ParallaxJellyfin

struct MovieDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var viewModel: MovieDetailViewModel?
    @State private var playerItem: ItemDetail?

    var body: some View {
        Group {
            if let vm = viewModel {
                switch vm.state {
                case .idle, .loading:
                    ProgressView().padding(40)
                case .loaded(let md):
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s18) {
                            HeroBackdrop(height: hSize == .regular ? 540 : 380) {
                                JellyfinImage(
                                    ref: md.movie.imageRef(.backdrop(index: 0)),
                                    kind: .backdrop(index: 0),
                                    session: session,
                                    maxWidth: 1600,
                                    aspectRatio: JellyfinImage.landscape,
                                    fillsProposedFrame: true
                                )
                            } foreground: {
                                VStack(alignment: .leading, spacing: Space.s12) {
                                    Text(md.movie.title)
                                        .scaledFont(hSize == .regular ? 48 : 30, relativeTo: .largeTitle, weight: .heavy)
                                        .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                                    if let sub = subtitle(md) {
                                        Text(sub).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                                    }
                                    HStack(spacing: Space.s12) {
                                        PrimaryPlayButton(title: "Play", fillWidth: false) {
                                            playerItem = .movie(md)
                                        }
                                        CircleGlassButton(
                                            systemImage: vm.isFavorite ? "heart.fill" : "heart",
                                            isActive: vm.isFavorite,
                                            accessibilityLabel: "Favorite"
                                        ) { Task { await vm.toggleFavorite() } }
                                        CircleGlassButton(
                                            systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                                            isActive: vm.isPlayed,
                                            accessibilityLabel: vm.isPlayed ? "Watched" : "Mark Watched"
                                        ) { Task { await vm.togglePlayed() } }
                                    }
                                    .padding(.top, Space.s8)
                                }
                            }

                            if let tagline = md.tagline {
                                Text(tagline)
                                    .italic()
                                    .foregroundStyle(Color.secondaryLabel)
                                    .padding(.horizontal, Space.s18)
                            }
                            if let overview = md.movie.overview {
                                Text(overview)
                                    .padding(.horizontal, Space.s18)
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
                    .scrollEdgeEffectHidden(true, for: .top)
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load this title",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
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

    private func subtitle(_ md: MovieDetail) -> String? {
        var parts: [String] = []
        if let y = md.movie.year { parts.append(String(y)) }
        if let r = md.movie.runtime {
            let mins = Int(r.components.seconds / 60)
            parts.append("\(mins) min")
        }
        if let cr = md.movie.communityRating {
            parts.append(String(format: "★ %.1f", cr))
        }
        if let or = md.movie.officialRating {
            parts.append(or)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

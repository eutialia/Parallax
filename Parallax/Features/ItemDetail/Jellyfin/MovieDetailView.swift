import SwiftUI
import ParallaxJellyfin

struct MovieDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
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
                        VStack(alignment: .leading, spacing: 16) {
                            DetailHeader(
                                title: md.movie.title,
                                subtitle: subtitle(md),
                                backdropRef: md.movie.imageRef(.backdrop(index: 0)),
                                session: session
                            )

                            PrimaryPlayButton(title: "Play") {
                                playerItem = .movie(md)
                            }
                            .padding(.horizontal, Space.s18)

                            HStack(spacing: Space.s12) {
                                actionButton(
                                    systemImage: vm.isFavorite ? "heart.fill" : "heart",
                                    label: "Favorite",
                                    isActive: vm.isFavorite
                                ) { Task { await vm.toggleFavorite() } }
                                actionButton(
                                    systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                                    label: vm.isPlayed ? "Watched" : "Mark Watched",
                                    isActive: vm.isPlayed
                                ) { Task { await vm.togglePlayed() } }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Space.s18)

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
                                metadataLine(label: "Studios", value: md.studios.joined(separator: ", "))
                            }
                            if !md.people.isEmpty {
                                metadataLine(label: "Cast & Crew", value: md.people.prefix(10).joined(separator: ", "))
                            }
                            if !md.movie.genres.isEmpty {
                                metadataLine(label: "Genres", value: md.movie.genres.joined(separator: ", "))
                            }
                        }
                        .padding(.vertical)
                    }
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
        .toolbar(.visible, for: .navigationBar)
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

    @ViewBuilder
    private func actionButton(systemImage: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s8) {
                Image(systemName: systemImage)
                Text(label).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isActive ? Color.label : Color.secondaryLabel)
            .padding(.horizontal, Space.s14).frame(height: 40)
            .glassPanel(cornerRadius: Radius.field)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func metadataLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Color.secondaryLabel)
            Text(value).font(.callout).foregroundStyle(Color.label)
        }
        .padding(.horizontal, Space.s18)
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

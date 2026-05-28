import SwiftUI
import ParallaxJellyfin

struct MovieDetailView: View {
    let itemID: ItemID
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: MovieDetailViewModel?

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
                                logoRef: md.movie.imageRef(.logo),
                                session: session
                            )

                            Button {
                                // Phase 4 wires playback.
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                            .padding(.horizontal, 20)

                            if let tagline = md.tagline {
                                Text(tagline)
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 20)
                            }
                            if let overview = md.movie.overview {
                                Text(overview)
                                    .padding(.horizontal, 20)
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
        .task {
            if viewModel == nil {
                let repo = await deps.libraryRepoFactory(session)
                viewModel = MovieDetailViewModel(repo: repo, itemID: itemID)
                await viewModel?.load()
            }
        }
    }

    @ViewBuilder
    private func metadataLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
        .padding(.horizontal, 20)
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

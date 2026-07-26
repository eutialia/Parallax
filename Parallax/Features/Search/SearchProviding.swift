import Foundation
import ParallaxCore
import ParallaxJellyfin

/// One searchable source. Search aggregates across every configured source, so it talks to this
/// rather than to a Jellyfin repository directly.
///
/// `canSearch` is the seam for SMB (and any future local source): a source that has no search index
/// yet reports `false` and is skipped, contributing nothing instead of throwing. That keeps the
/// aggregate honest — "this source can't answer" is not "the search failed" — and means SMB
/// filename search can arrive as a new conformer with no changes to the view model, the results
/// view, or the tab's visibility rule.
protocol SearchProviding: Sendable {
    /// Tags every result so the UI can dispatch artwork, playback, and user-data writes to the
    /// right server.
    var source: LibrarySource { get }
    /// Whether this source can answer queries at all. A `false` provider is never called.
    var canSearch: Bool { get }
    func search(_ query: String, scope: SearchScope) async throws -> SearchResults
}

/// A Jellyfin server as a search source — always searchable; the server owns the index.
struct JellyfinSearchProvider: SearchProviding {
    let source: LibrarySource
    let canSearch = true
    private let repo: LibraryRepository

    init(session: Session, repo: LibraryRepository) {
        self.source = .jellyfin(session)
        self.repo = repo
    }

    func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        try await repo.search(query, scope: scope)
    }

    /// One provider per signed-in Jellyfin server, in the store's order. Repos are built
    /// concurrently (the factory hops an actor per session).
    static func all(
        for sessions: [Session],
        repoFactory: @Sendable @escaping (Session) async -> LibraryRepository
    ) async -> [JellyfinSearchProvider] {
        // Only the repo build runs off-actor; the provider is assembled back here, because its
        // `init` is MainActor-isolated (the target's default isolation) and constructing it inside
        // the child task is an isolation violation the compiler warns about.
        await withTaskGroup(of: (Int, Session, LibraryRepository).self) { group in
            for (index, session) in sessions.enumerated() {
                group.addTask { (index, session, await repoFactory(session)) }
            }
            var out: [(Int, Session, LibraryRepository)] = []
            for await result in group { out.append(result) }
            return out.sorted { $0.0 < $1.0 }.map { JellyfinSearchProvider(session: $0.1, repo: $0.2) }
        }
    }
}

/// Search results merged across sources, each item still carrying the server it came from.
///
/// The groups stay separate (rather than one flat list) because the results screen renders them as
/// distinct sections with their own column counts — posters for shows and movies, landscape stills
/// for episodes.
struct AggregatedSearchResults: Hashable {
    var series: [SourcedItem] = []
    var movies: [SourcedItem] = []
    var episodes: [SourcedItem] = []

    var isEmpty: Bool { series.isEmpty && movies.isEmpty && episodes.isEmpty }

    static let empty = AggregatedSearchResults()

    /// Interleave each source's results round-robin, group by group.
    ///
    /// There is no cross-server relevance score to sort on — each server ranks its own hits with no
    /// shared scale — so inventing a global ordering would be a fiction. Round-robin gives every
    /// server presence near the top instead of burying the second server beneath the whole of the
    /// first, and it's stable and explicable. Within a server, its own ranking is preserved.
    static func interleaving(_ perSource: [(source: LibrarySource, results: SearchResults)]) -> AggregatedSearchResults {
        AggregatedSearchResults(
            series: .interleaved(perSource.map { entry in
                entry.results.series.map { SourcedItem(item: .series($0), source: entry.source) }
            }),
            movies: .interleaved(perSource.map { entry in
                entry.results.movies.map { SourcedItem(item: .movie($0), source: entry.source) }
            }),
            episodes: .interleaved(perSource.map { entry in
                entry.results.episodes.map { SourcedItem(item: .episode($0), source: entry.source) }
            })
        )
    }

    /// Patch a single item's user data wherever it appears. Matches on (source, itemID) — an id
    /// alone can't identify an item across servers.
    func patching(itemID: ItemID, source: MediaSourceID, _ transform: (Item) -> Item) -> AggregatedSearchResults {
        func patch(_ list: [SourcedItem]) -> [SourcedItem] {
            list.map { sourced in
                guard sourced.item.id == itemID, sourced.source.sourceID == source else { return sourced }
                return SourcedItem(item: transform(sourced.item), source: sourced.source)
            }
        }
        return AggregatedSearchResults(series: patch(series), movies: patch(movies), episodes: patch(episodes))
    }

    func contains(itemID: ItemID, source: MediaSourceID) -> Bool {
        [series, movies, episodes].contains { list in
            list.contains { $0.item.id == itemID && $0.source.sourceID == source }
        }
    }
}

import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// The two cross-server merge rules the aggregated surfaces are built on. Both are pure functions
/// over finite lists, so they're tested directly rather than through a view model.
@Suite("Cross-server item merging")
@MainActor
struct SourcedItemMergeTests {
    private func source(_ id: String) -> LibrarySource {
        .jellyfin(Session(
            id: ServerID(rawValue: id),
            data: JellyfinServerData(
                serverURL: URL(string: "https://\(id).example.test")!,
                serverName: "Server \(id)",
                user: UserSnapshot(id: "u-\(id)", name: "User", serverLastUpdatedAt: nil)
            ),
            accessToken: "tok-\(id)"
        ))
    }

    private func movie(_ id: String, lastPlayed: Date?) -> Item {
        .movie(Movie(
            id: ItemID(rawValue: id), title: id, overview: nil, year: nil, runtime: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            userData: UserItemData(
                played: false, playbackPositionTicks: 1, playCount: 0,
                isFavorite: false, lastPlayedDate: lastPlayed
            )
        ))
    }

    private func at(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(minutes * 60))
    }

    // MARK: - Continue Watching

    @Test("Continue Watching interleaves servers by play date, newest first — not server-by-server")
    func mergesByLastPlayedAcrossServers() {
        let a = source("a")
        let b = source("b")
        // Each server is internally sorted newest-first, as Jellyfin returns them.
        let fromA = [
            SourcedItem(item: movie("a-newest", lastPlayed: at(50)), source: a),
            SourcedItem(item: movie("a-old", lastPlayed: at(10)), source: a),
        ]
        let fromB = [
            SourcedItem(item: movie("b-mid", lastPlayed: at(30)), source: b),
            SourcedItem(item: movie("b-oldest", lastPlayed: at(5)), source: b),
        ]

        let merged = [SourcedItem].mergedByLastPlayed([fromA, fromB])

        // A plain concatenation would give a-newest, a-old, b-mid, b-oldest — "all of server A,
        // then all of server B", which reads as stale-then-fresh. One timeline instead:
        #expect(merged.map(\.item.id.rawValue) == ["a-newest", "b-mid", "a-old", "b-oldest"])
    }

    @Test("Items with no play date sort last, keeping a stable relative order")
    func undatedItemsSortLastStably() {
        let a = source("a")
        let items = [
            SourcedItem(item: movie("undated-1", lastPlayed: nil), source: a),
            SourcedItem(item: movie("dated", lastPlayed: at(10)), source: a),
            SourcedItem(item: movie("undated-2", lastPlayed: nil), source: a),
        ]

        let merged = [SourcedItem].mergedByLastPlayed([items])

        #expect(merged.map(\.item.id.rawValue) == ["dated", "undated-1", "undated-2"])
    }

    @Test("Equal play dates keep input order rather than an arbitrary one")
    func tiesAreStable() {
        let a = source("a")
        let b = source("b")
        let same = at(20)
        let merged = [SourcedItem].mergedByLastPlayed([
            [SourcedItem(item: movie("first", lastPlayed: same), source: a)],
            [SourcedItem(item: movie("second", lastPlayed: same), source: b)],
        ])

        #expect(merged.map(\.item.id.rawValue) == ["first", "second"])
    }

    // MARK: - Round-robin

    @Test("Round-robin gives each server presence near the top and preserves its own ranking")
    func interleavesRoundRobin() {
        let a = source("a")
        let b = source("b")
        let fromA = ["a1", "a2", "a3"].map { SourcedItem(item: movie($0, lastPlayed: nil), source: a) }
        let fromB = ["b1", "b2"].map { SourcedItem(item: movie($0, lastPlayed: nil), source: b) }

        let merged = [SourcedItem].interleaved([fromA, fromB])

        // Server B's top hit lands second, not fourth — the point of round-robin over concatenation.
        #expect(merged.map(\.item.id.rawValue) == ["a1", "b1", "a2", "b2", "a3"])
    }

    @Test("A shorter list just runs out; the longer one continues")
    func interleaveHandlesUnevenLists() {
        let a = source("a")
        let merged = [SourcedItem].interleaved([
            [SourcedItem(item: movie("only", lastPlayed: nil), source: a)],
            [],
        ])
        #expect(merged.map(\.item.id.rawValue) == ["only"])
    }

    // MARK: - Identity

    @Test("Two servers holding the SAME item id produce distinct identities")
    func sameItemIDAcrossServersDoesNotCollide() {
        // Jellyfin derives item GUIDs deterministically from the media path, so two servers over a
        // mirrored layout genuinely can mint the same id. A `ForEach` keyed on the raw ItemID would
        // silently drop one tile.
        let shared = movie("same-guid", lastPlayed: nil)
        let fromA = SourcedItem(item: shared, source: source("a"))
        let fromB = SourcedItem(item: shared, source: source("b"))

        #expect(fromA.id != fromB.id)
        #expect(Set([fromA.id, fromB.id]).count == 2)
    }

    // MARK: - Search interleaving

    @Test("Search interleaves each group independently, tagging every hit with its server")
    func searchResultsInterleavePerGroup() {
        let a = source("a")
        let b = source("b")
        func results(_ prefix: String) -> SearchResults {
            SearchResults(
                movies: [Movie(
                    id: ItemID(rawValue: "\(prefix)-m"), title: "m", overview: nil, year: nil,
                    runtime: nil, communityRating: nil, officialRating: nil, genres: [],
                    primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
                    userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
                )],
                series: [],
                episodes: []
            )
        }

        let merged = AggregatedSearchResults.interleaving([
            (source: a, results: results("a")),
            (source: b, results: results("b")),
        ])

        #expect(merged.movies.map(\.item.id.rawValue) == ["a-m", "b-m"])
        #expect(merged.movies.map(\.source.sourceID) == [a.sourceID, b.sourceID])
        #expect(merged.series.isEmpty)
    }

    @Test("Patching search results matches on (source, itemID), never the id alone")
    func searchPatchIsSourceScoped() {
        let a = source("a")
        let b = source("b")
        let shared = movie("same-guid", lastPlayed: nil)
        let results = AggregatedSearchResults(
            movies: [SourcedItem(item: shared, source: a), SourcedItem(item: shared, source: b)]
        )

        let patched = results.patching(itemID: ItemID(rawValue: "same-guid"), source: a.sourceID) {
            $0.withFavorite(true)
        }

        // Only server A's copy flips; server B's identically-identified item is untouched.
        #expect(patched.movies[0].item.userData.isFavorite)
        #expect(patched.movies[1].item.userData.isFavorite == false)
    }
}

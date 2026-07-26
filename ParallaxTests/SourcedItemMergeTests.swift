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
    /// A partially-watched movie (a non-zero position is what puts it on the Continue
    /// Watching row at all) whose only interesting field is its play date.
    private func movie(_ id: String, lastPlayed: Date?) -> Item {
        makeMovieItem(id, positionTicks: 1, lastPlayed: lastPlayed)
    }

    private func at(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(minutes * 60))
    }

    // MARK: - Continue Watching

    @Test("Continue Watching interleaves servers by play date, newest first — not server-by-server")
    func mergesByLastPlayedAcrossServers() {
        let a = makeJellyfinSource("a")
        let b = makeJellyfinSource("b")
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
        let a = makeJellyfinSource("a")
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
        let a = makeJellyfinSource("a")
        let b = makeJellyfinSource("b")
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
        let a = makeJellyfinSource("a")
        let b = makeJellyfinSource("b")
        let fromA = ["a1", "a2", "a3"].map { SourcedItem(item: movie($0, lastPlayed: nil), source: a) }
        let fromB = ["b1", "b2"].map { SourcedItem(item: movie($0, lastPlayed: nil), source: b) }

        let merged = [SourcedItem].interleaved([fromA, fromB])

        // Server B's top hit lands second, not fourth — the point of round-robin over concatenation.
        #expect(merged.map(\.item.id.rawValue) == ["a1", "b1", "a2", "b2", "a3"])
    }

    @Test("A shorter list just runs out; the longer one continues")
    func interleaveHandlesUnevenLists() {
        let a = makeJellyfinSource("a")
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
        let fromA = SourcedItem(item: shared, source: makeJellyfinSource("a"))
        let fromB = SourcedItem(item: shared, source: makeJellyfinSource("b"))

        #expect(fromA.id != fromB.id)
        #expect(Set([fromA.id, fromB.id]).count == 2)
    }

    // MARK: - Search interleaving

    /// "Each group INDEPENDENTLY" is the claim, so every group carries a different per-server count:
    /// movies 2/1, series 1/2, episodes 0/1. A single shared round-robin cursor across the groups —
    /// or a group accidentally reading another group's list — can't survive all three at once, which
    /// a movies-only fixture (with `series`/`episodes` empty) never tested.
    @Test("Search interleaves each group independently, tagging every hit with its server")
    func searchResultsInterleavePerGroup() {
        let a = makeJellyfinSource("a")
        let b = makeJellyfinSource("b")
        let fromA = SearchResults(
            movies: [makeMovie("a-m1"), makeMovie("a-m2")],
            series: [makeSeries("a-s1")],
            episodes: []
        )
        let fromB = SearchResults(
            movies: [makeMovie("b-m1")],
            series: [makeSeries("b-s1"), makeSeries("b-s2")],
            episodes: [makeEpisode("b-e1")]
        )

        let merged = AggregatedSearchResults.interleaving([
            (source: a, results: fromA),
            (source: b, results: fromB),
        ])

        // Round-robin per group: B's single movie lands second, and B's second series lands after
        // A's list has run out.
        #expect(merged.movies.map(\.item.id.rawValue) == ["a-m1", "b-m1", "a-m2"])
        #expect(merged.movies.map(\.source.sourceID) == [a.sourceID, b.sourceID, a.sourceID])
        #expect(merged.series.map(\.item.id.rawValue) == ["a-s1", "b-s1", "b-s2"])
        #expect(merged.series.map(\.source.sourceID) == [a.sourceID, b.sourceID, b.sourceID])
        // A group only one server answered still comes through, tagged with that server.
        #expect(merged.episodes.map(\.item.id.rawValue) == ["b-e1"])
        #expect(merged.episodes.map(\.source.sourceID) == [b.sourceID])
    }

    @Test("Patching search results matches on (source, itemID), never the id alone")
    func searchPatchIsSourceScoped() {
        let a = makeJellyfinSource("a")
        let b = makeJellyfinSource("b")
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

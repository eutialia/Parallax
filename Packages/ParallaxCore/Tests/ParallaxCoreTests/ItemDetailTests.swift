import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("ItemDetail")
struct ItemDetailTests {
    private let movie = LibraryFixtures.movie(id: "m1")
    private let series = LibraryFixtures.series(id: "s1")
    private let season = LibraryFixtures.season(id: "se1")
    private let episode = LibraryFixtures.episode(id: "e1")

    private func movieDetail(chapters: [Chapter] = []) -> MovieDetail {
        MovieDetail(
            movie: movie, tagline: "Your mind is the scene of the crime.",
            studios: ["Legendary"], directors: ["Christopher Nolan"],
            people: ["Leonardo DiCaprio"], chapters: chapters
        )
    }

    /// The detail enum's id must reach through to the wrapped MODEL's id, not invent one — the
    /// navigation stack matches pushed details against the item that opened them.
    @Test("id reaches through to the wrapped model's id")
    func idReachesTheModel() {
        #expect(ItemDetail.movie(movieDetail()).id == movie.id)
        #expect(ItemDetail.series(SeriesDetail(series: series, tagline: nil, studios: [], people: [])).id == series.id)
        #expect(ItemDetail.season(SeasonDetail(season: season, overview: nil)).id == season.id)
        #expect(ItemDetail.episode(EpisodeDetail(episode: episode, people: [])).id == episode.id)
    }

    /// A mutated copy, NOT a re-init listing every field — the pattern that silently zeroes a
    /// newly added field as the struct grows.
    @Test("withMovie swaps the movie and keeps every ledger field")
    func withMoviePreservesLedger() {
        let original = movieDetail(chapters: [Chapter(index: 0, name: "Opening", start: .zero)])
        let updated = original.withMovie(movie.withUserData(LibraryFixtures.userData(played: true)))

        #expect(updated.movie.userData.played)
        #expect(updated.tagline == original.tagline)
        #expect(updated.studios == original.studios)
        #expect(updated.directors == original.directors)
        #expect(updated.people == original.people)
        #expect(updated.chapters == original.chapters)
        #expect(updated.withMovie(original.movie) == original)
    }

    @Test("withSeries swaps the series and keeps every ledger field")
    func withSeriesPreservesLedger() {
        let original = SeriesDetail(
            series: series, tagline: "All hail the king.", studios: ["Sony"], people: ["Bryan Cranston"]
        )
        let updated = original.withSeries(series.withUserData(LibraryFixtures.userData(isFavorite: true)))

        #expect(updated.series.userData.isFavorite)
        #expect(updated.tagline == original.tagline)
        #expect(updated.studios == original.studios)
        #expect(updated.people == original.people)
        #expect(updated.withSeries(original.series) == original)
    }

    /// Chapters default to empty: not every source ships them, and the detail screen decides
    /// whether to draw the row from the count.
    @Test("chapters default to empty on both detail types that carry them")
    func chaptersDefaultEmpty() {
        #expect(movieDetail().chapters.isEmpty)
        #expect(EpisodeDetail(episode: episode, people: []).chapters.isEmpty)
    }
}

@Suite("Chapter")
struct ChapterTests {
    /// The chapter's identity is its index — the name is optional (Jellyfin auto-names unnamed
    /// chapters server-side, but the model doesn't assume it did).
    @Test("identity is the index, so unnamed chapters stay addressable")
    func identityIsTheIndex() {
        let unnamed = Chapter(index: 3, name: nil, start: .seconds(600))
        #expect(unnamed.id == 3)
        #expect(unnamed.name == nil)
    }

    @Test("chapters at different indices are distinct even with equal names and starts")
    func distinctByIndex() {
        let first = Chapter(index: 0, name: "Intro", start: .zero)
        let second = Chapter(index: 1, name: "Intro", start: .zero)
        #expect(first != second)
    }
}

@Suite("AdjacentEpisodes")
struct AdjacentEpisodesTests {
    private func episode(_ id: String, index: Int) -> Episode {
        LibraryFixtures.episode(id: id, indexNumber: index)
    }

    /// The neighbours are simply the elements either side of the queried episode in the server's
    /// aired-order window — no IndexNumber arithmetic, which mishandles interleaved specials and
    /// season boundaries.
    @Test("the middle of a window resolves both neighbours")
    func resolvesBothNeighbours() {
        let window = [episode("a", index: 1), episode("b", index: 2), episode("c", index: 3)]
        let adjacent = AdjacentEpisodes(around: ItemID(rawValue: "b"), in: window)

        #expect(adjacent.previous?.id == ItemID(rawValue: "a"))
        #expect(adjacent.next?.id == ItemID(rawValue: "c"))
    }

    @Test("the series' first episode has no previous")
    func firstEpisodeHasNoPrevious() {
        let window = [episode("a", index: 1), episode("b", index: 2)]
        let adjacent = AdjacentEpisodes(around: ItemID(rawValue: "a"), in: window)

        #expect(adjacent.previous == nil)
        #expect(adjacent.next?.id == ItemID(rawValue: "b"))
    }

    @Test("the series' last episode has no next")
    func lastEpisodeHasNoNext() {
        let window = [episode("a", index: 1), episode("b", index: 2)]
        let adjacent = AdjacentEpisodes(around: ItemID(rawValue: "b"), in: window)

        #expect(adjacent.previous?.id == ItemID(rawValue: "a"))
        #expect(adjacent.next == nil)
    }

    @Test("a single-item window has no neighbours at all")
    func singleItemWindow() {
        let adjacent = AdjacentEpisodes(around: ItemID(rawValue: "a"), in: [episode("a", index: 1)])
        #expect(adjacent.previous == nil)
        #expect(adjacent.next == nil)
    }

    /// A window that doesn't contain the queried episode is a server-shape surprise: resolve to
    /// no neighbours rather than guessing at position 0.
    @Test("a window missing the queried episode resolves to none")
    func missingFromWindow() {
        let window = [episode("a", index: 1), episode("b", index: 2)]
        let adjacent = AdjacentEpisodes(around: ItemID(rawValue: "zz"), in: window)

        #expect(adjacent.previous == nil)
        #expect(adjacent.next == nil)
        #expect(adjacent == .none)
    }

    @Test("an empty window resolves to none")
    func emptyWindow() {
        #expect(AdjacentEpisodes(around: ItemID(rawValue: "a"), in: []) == .none)
    }

    @Test(".none carries neither neighbour")
    func noneIsEmpty() {
        #expect(AdjacentEpisodes.none.previous == nil)
        #expect(AdjacentEpisodes.none.next == nil)
    }
}

import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("Library primitives")
struct LibraryPrimitivesTests {
    @Test("Typed ID wrappers are distinct value types")
    func typedIDs() {
        let item = ItemID(rawValue: "abc")
        let coll = CollectionID(rawValue: "abc")
        let tag = ImageTag(rawValue: "abc")
        #expect(item.rawValue == coll.rawValue)
        #expect(item.rawValue == tag.rawValue)
        // The point of the wrappers is that the type system rejects
        // cross-assignment. That's a compile-time guarantee — these
        // runtime checks only prove the value-equality semantics on
        // `rawValue`, not the type-system distinctness.
        #expect(ItemID(rawValue: "abc") == ItemID(rawValue: "abc"))
        #expect(ItemID(rawValue: "abc") != ItemID(rawValue: "xyz"))
    }

    @Test("Page exposes items, total, and nextCursor")
    func pageShape() {
        let cursor = PageCursor.startIndex(50)
        let page = Page(items: [1, 2, 3], total: 120, nextCursor: cursor)
        #expect(page.items == [1, 2, 3])
        #expect(page.total == 120)
        #expect(page.nextCursor == cursor)
    }

    @Test("ItemSort default for library is title ascending")
    func itemSortDefault() {
        let s = ItemSort.defaultForLibrary
        #expect(s.field == .title)
        #expect(s.direction == .ascending)
    }

    @Test("ItemFilter default is no constraints")
    func itemFilterDefault() {
        let f = ItemFilter()
        #expect(f.watchState == .all)
        #expect(f.favoritesOnly == false)
    }

    @Test("SearchResults default is empty")
    func searchResultsEmpty() {
        let r = SearchResults(movies: [], series: [], episodes: [])
        #expect(r.movies.isEmpty)
        #expect(r.series.isEmpty)
        #expect(r.episodes.isEmpty)
    }

    @Test("UserItemData.playedFraction divides position by runtime ticks")
    func playedFraction() {
        let data = UserItemData(played: false, playbackPositionTicks: 5_000_000_000, playCount: 0, isFavorite: false)
        let fraction = data.playedFraction(runtimeTicks: 10_000_000_000)
        #expect(fraction == 0.5)
        #expect(data.playedFraction(runtimeTicks: nil) == nil)
        #expect(data.playedFraction(runtimeTicks: 0) == nil)
    }

    @Test("UserItemData.remainingMinutes rounds up from playback position")
    func remainingMinutes() {
        // 30 min into a 60 min item → 30 min left.
        let data = UserItemData(played: false, playbackPositionTicks: 18_000_000_000, playCount: 0, isFavorite: false)
        #expect(data.remainingMinutes(runtime: .seconds(3600)) == 30)
        #expect(data.remainingMinutes(runtime: nil) == nil)
    }

    @Test("Movie.imageRef returns nil when the relevant tag is missing")
    func movieImageRefNil() {
        let movie = Movie(
            id: ItemID(rawValue: "m1"),
            title: "Test",
            overview: nil, year: nil, runtime: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
        #expect(movie.imageRef(.primary) == nil)
        #expect(movie.imageRef(.backdrop(index: 0)) == nil)
        #expect(movie.imageRef(.logo) == nil)
    }

    @Test("Movie.imageRef returns the tag when present")
    func movieImageRefPresent() {
        let movie = Movie(
            id: ItemID(rawValue: "m1"),
            title: "Test",
            overview: nil, year: nil, runtime: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: ImageTag(rawValue: "p"),
            backdropTags: [ImageTag(rawValue: "b0"), ImageTag(rawValue: "b1")],
            logoTag: ImageTag(rawValue: "l"),
            thumbTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
        #expect(movie.imageRef(.primary)?.tag.rawValue == "p")
        #expect(movie.imageRef(.backdrop(index: 1))?.tag.rawValue == "b1")
        #expect(movie.imageRef(.backdrop(index: 5)) == nil)
        #expect(movie.imageRef(.logo)?.tag.rawValue == "l")
    }

    @Test("Series.imageRef supports primary/backdrop/logo/thumb/banner; nil for art/disc")
    func seriesImageRefSupportedKinds() {
        let series = Series(
            id: ItemID(rawValue: "s1"), title: "T",
            overview: nil, year: nil, status: nil, genres: [],
            primaryTag: ImageTag(rawValue: "p"),
            backdropTags: [ImageTag(rawValue: "b0")],
            logoTag: ImageTag(rawValue: "l"),
            thumbTag: ImageTag(rawValue: "th"),
            bannerTag: ImageTag(rawValue: "bn"),
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
        #expect(series.imageRef(.primary)?.tag.rawValue == "p")
        #expect(series.imageRef(.backdrop(index: 0))?.tag.rawValue == "b0")
        #expect(series.imageRef(.logo)?.tag.rawValue == "l")
        #expect(series.imageRef(.thumb)?.tag.rawValue == "th")
        #expect(series.imageRef(.banner)?.tag.rawValue == "bn")
        #expect(series.imageRef(.art) == nil)
        #expect(series.imageRef(.disc) == nil)
    }

    @Test("Season.imageRef supports only primary + thumb")
    func seasonImageRef() {
        let season = Season(
            id: ItemID(rawValue: "se1"), seriesID: ItemID(rawValue: "ser1"),
            name: "S1", indexNumber: 1,
            primaryTag: ImageTag(rawValue: "p"),
            thumbTag: ImageTag(rawValue: "th"),
            episodeCount: 7
        )
        #expect(season.imageRef(.primary)?.tag.rawValue == "p")
        #expect(season.imageRef(.thumb)?.tag.rawValue == "th")
        #expect(season.imageRef(.backdrop(index: 0)) == nil)
        #expect(season.imageRef(.logo) == nil)
        #expect(season.imageRef(.banner) == nil)
    }

    @Test("Episode.imageRef supports only primary; other kinds return nil")
    func episodeImageRef() {
        let ep = Episode(
            id: ItemID(rawValue: "e1"), seriesID: ItemID(rawValue: "ser1"),
            seasonID: ItemID(rawValue: "se1"), name: "Pilot",
            indexNumber: 1, parentIndexNumber: 1,
            overview: nil, runtime: nil,
            primaryTag: ImageTag(rawValue: "p"),
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
        #expect(ep.imageRef(.primary)?.tag.rawValue == "p")
        #expect(ep.imageRef(.backdrop(index: 0)) == nil)
        #expect(ep.imageRef(.logo) == nil)
        #expect(ep.imageRef(.thumb) == nil)
        #expect(ep.imageRef(.banner) == nil)
    }

    @Test("Item enum exposes id regardless of concrete case")
    func itemID() {
        let movie = Movie(
            id: ItemID(rawValue: "m"), title: "M",
            overview: nil, year: nil, runtime: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
        #expect(Item.movie(movie).id == ItemID(rawValue: "m"))
    }
}

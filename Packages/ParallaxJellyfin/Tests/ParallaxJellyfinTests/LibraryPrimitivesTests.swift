import Foundation
import Testing
import ParallaxCore
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

    @Test("ItemSort default for library is release date, newest first")
    func itemSortDefault() {
        let s = ItemSort.defaultForLibrary
        #expect(s.field == .releaseDate)
        #expect(s.direction == .descending)
    }

    @Test("ItemSort natural directions: dates and ratings descend, titles ascend")
    func itemSortNaturalDirections() {
        #expect(ItemSort.Field.releaseDate.naturalDirection == .descending)
        #expect(ItemSort.Field.dateAdded.naturalDirection == .descending)
        #expect(ItemSort.Field.communityRating.naturalDirection == .descending)
        #expect(ItemSort.Field.officialRating.naturalDirection == .descending)
        #expect(ItemSort.Field.title.naturalDirection == .ascending)
    }

    @Test("ItemFilter default is no constraints")
    func itemFilterDefault() {
        let f = ItemFilter()
        #expect(f.genres.isEmpty)
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

    @Test("Episode shelf footer caption and progress for in-progress playback")
    func episodeShelfFooter() {
        let episode = Episode(
            id: ItemID(rawValue: "e1"),
            seriesID: ItemID(rawValue: "s1"),
            seasonID: ItemID(rawValue: "se1"),
            name: "Pilot",
            seriesName: "Preview Show",
            indexNumber: 2,
            parentIndexNumber: 1,
            overview: nil,
            runtime: .seconds(3600),
            primaryTag: nil,
            userData: UserItemData(
                played: false,
                playbackPositionTicks: 18_000_000_000,
                playCount: 0,
                isFavorite: false
            )
        )
        #expect(episode.shelfFooterCaption() == "S1 · E2 · 30 min left")
        #expect(episode.shelfFooterCaption(showTimeRemaining: false) == "S1 · E2 · 60 min")
        #expect(episode.shelfPlaybackProgress == 0.5)
    }

    @Test("Episode shelf footer shows runtime without progress when unwatched")
    func episodeShelfFooterUnwatchedShowsRuntimeNotProgress() {
        let episode = Episode(
            id: ItemID(rawValue: "e1"),
            seriesID: ItemID(rawValue: "s1"),
            seasonID: ItemID(rawValue: "se1"),
            name: "Pilot",
            seriesName: "Preview Show",
            indexNumber: 2,
            parentIndexNumber: 1,
            overview: nil,
            runtime: .seconds(3600),
            primaryTag: nil,
            userData: .absent
        )
        #expect(episode.shelfFooterCaption() == "S1 · E2 · 60 min")
        #expect(episode.shelfFooterCaption(showRuntimeLength: false) == "S1 · E2")
        #expect(episode.shelfPlaybackProgress == nil)
    }

    @Test("Episode seriesContextCaption joins index and series, dropping blank parts")
    func episodeSeriesContextCaption() {
        func episode(seriesName: String?, index: Int?) -> Episode {
            Episode(
                id: ItemID(rawValue: "e1"),
                seriesID: ItemID(rawValue: "s1"),
                seasonID: ItemID(rawValue: "se1"),
                name: "Pilot",
                seriesName: seriesName,
                indexNumber: index,
                parentIndexNumber: index == nil ? nil : 1,
                overview: nil,
                runtime: nil,
                primaryTag: nil,
                userData: .absent
            )
        }
        #expect(episode(seriesName: "Breaking Bad", index: 2).seriesContextCaption == "S1 · E2 · Breaking Bad")
        // A blank server-side SeriesName must not leave a dangling separator.
        #expect(episode(seriesName: "", index: 2).seriesContextCaption == "S1 · E2")
        #expect(episode(seriesName: "Breaking Bad", index: nil).seriesContextCaption == "Breaking Bad")
        #expect(episode(seriesName: nil, index: nil).seriesContextCaption == nil)
    }

    @Test("Episode indexedNameCaption is a list ordinal, degrading without index or name")
    func episodeIndexedNameCaption() {
        func episode(name: String, index: Int?) -> Episode {
            Episode(
                id: ItemID(rawValue: "e1"),
                seriesID: ItemID(rawValue: "s1"),
                seasonID: ItemID(rawValue: "se1"),
                name: name,
                seriesName: "Preview Show",
                indexNumber: index,
                parentIndexNumber: index == nil ? nil : 1,
                overview: nil,
                runtime: nil,
                primaryTag: nil,
                userData: .absent
            )
        }
        // The season-row surface: the season is context, so no "S1" prefix — a bare ordinal.
        #expect(episode(name: "Pilot", index: 3).indexedNameCaption == "3. Pilot")
        #expect(episode(name: "Pilot", index: nil).indexedNameCaption == "Pilot")
        // A blank server-side Name must not leave a dangling "3. ".
        #expect(episode(name: "", index: 3).indexedNameCaption == "E3")
        #expect(episode(name: "", index: nil).indexedNameCaption == "")
    }

    @Test("Episode timeCaption never shows time left once played, despite stale position ticks")
    func episodeTimeCaptionPlayedGate() {
        let episode = Episode(
            id: ItemID(rawValue: "e1"),
            seriesID: ItemID(rawValue: "s1"),
            seasonID: ItemID(rawValue: "se1"),
            name: "Pilot",
            seriesName: nil,
            indexNumber: 2,
            parentIndexNumber: 1,
            overview: nil,
            runtime: .seconds(3600),
            primaryTag: nil,
            userData: UserItemData(
                played: true,
                playbackPositionTicks: 18_000_000_000,
                playCount: 1,
                isFavorite: false
            )
        )
        #expect(episode.timeCaption() == "60 min")
        #expect(episode.shelfFooterCaption() == "S1 · E2 · 60 min")
    }

    @Test("Episode shelf footer shows label only when playback is near end")
    func episodeShelfFooterNearEnd() {
        let episode = Episode(
            id: ItemID(rawValue: "e1"),
            seriesID: ItemID(rawValue: "s1"),
            seasonID: ItemID(rawValue: "se1"),
            name: "Pilot",
            seriesName: "Preview Show",
            indexNumber: 2,
            parentIndexNumber: 1,
            overview: nil,
            runtime: .seconds(3600),
            primaryTag: nil,
            userData: UserItemData(
                played: false,
                playbackPositionTicks: 36_000_000_000,
                playCount: 0,
                isFavorite: false
            )
        )
        #expect(episode.shelfFooterCaption() == "S1 · E2")
        #expect(episode.shelfPlaybackProgress == 1.0)
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
            overview: nil, year: nil, status: nil,
            communityRating: nil, officialRating: nil, genres: [],
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
            seriesName: nil,
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

    @Test("QualityBadge resolution returns 4K only for UHD dimensions")
    func qualityBadgeResolution() {
        #expect(QualityBadge.resolution(width: 3840, height: 2160) == "4K")
        #expect(QualityBadge.resolution(width: 1920, height: 1080) == nil)
        #expect(QualityBadge.resolution(width: nil, height: nil) == nil)
    }

    @Test("QualityBadge hdr collapses HDR flavours and handles DOVIInvalid")
    func qualityBadgeHDR() {
        #expect(QualityBadge.hdr("DOVI") == "HDR")
        #expect(QualityBadge.hdr("DOVIInvalid") == "HDR")
        #expect(QualityBadge.hdr("HDR10+") == "HDR")
        #expect(QualityBadge.hdr("HLG") == "HDR")
        #expect(QualityBadge.hdr("SDR") == nil)
        #expect(QualityBadge.hdr(nil) == nil)
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

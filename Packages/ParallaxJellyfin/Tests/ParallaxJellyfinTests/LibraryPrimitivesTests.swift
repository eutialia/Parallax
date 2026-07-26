import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("Library primitives")
struct LibraryPrimitivesTests {
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

    /// `SearchResults.empty` is what `LibraryRepository.search` short-circuits a blank query to,
    /// and what the search screen renders its "no results" state from — so emptiness has to be
    /// true ONLY when all three buckets are empty. A hit in any one of them must read as
    /// non-empty; a bucket-blind check would leave a series-only result looking like no result.
    @Test(
        "Emptiness holds only when every bucket is empty",
        arguments: [SearchBucket.none, .movies, .series, .episodes]
    )
    func searchResultsEmptiness(bucket: SearchBucket) {
        let movie = JellyfinFixtures.movie(id: "m1")
        let series = Series(
            id: ItemID(rawValue: "s1"), title: "S",
            overview: nil, year: nil, status: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil, bannerTag: nil,
            userData: .absent
        )
        let episode = JellyfinFixtures.episode(id: "e1")

        let results: SearchResults
        switch bucket {
        case .none: results = SearchResults(movies: [], series: [], episodes: [])
        case .movies: results = SearchResults(movies: [movie], series: [], episodes: [])
        case .series: results = SearchResults(movies: [], series: [series], episodes: [])
        case .episodes: results = SearchResults(movies: [], series: [], episodes: [episode])
        }

        // Compared against the production constant the repository actually returns, not a
        // hand-built "empty" the test invented.
        #expect((results == SearchResults.empty) == (bucket == .none))
    }

    enum SearchBucket: Sendable { case none, movies, series, episodes }

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
        let episode = JellyfinFixtures.episode(
            name: "Pilot",
            seriesName: "Preview Show",
            indexNumber: 2,
            runtime: .seconds(3600),
            userData: UserItemData(played: false, playbackPositionTicks: 18_000_000_000, playCount: 0, isFavorite: false)
        )
        #expect(episode.shelfFooterCaption() == "S1 · E2 · 30 min left")
        #expect(episode.shelfFooterCaption(showTimeRemaining: false) == "S1 · E2 · 60 min")
        #expect(episode.shelfPlaybackProgress == 0.5)
    }

    @Test("Episode shelf footer shows runtime without progress when unwatched")
    func episodeShelfFooterUnwatchedShowsRuntimeNotProgress() {
        let episode = JellyfinFixtures.episode(
            name: "Pilot",
            seriesName: "Preview Show",
            indexNumber: 2,
            runtime: .seconds(3600)
        )
        #expect(episode.shelfFooterCaption() == "S1 · E2 · 60 min")
        #expect(episode.shelfFooterCaption(showRuntimeLength: false) == "S1 · E2")
        #expect(episode.shelfPlaybackProgress == nil)
    }

    @Test("Episode seriesContextCaption joins index and series, dropping blank parts")
    func episodeSeriesContextCaption() {
        func episode(seriesName: String?, index: Int?) -> Episode {
            JellyfinFixtures.episode(
                name: "Pilot",
                seriesName: seriesName,
                indexNumber: index,
                parentIndexNumber: index == nil ? nil : 1
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
            JellyfinFixtures.episode(
                name: name,
                seriesName: "Preview Show",
                indexNumber: index,
                parentIndexNumber: index == nil ? nil : 1
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
        let episode = JellyfinFixtures.episode(
            name: "Pilot",
            indexNumber: 2,
            runtime: .seconds(3600),
            userData: UserItemData(played: true, playbackPositionTicks: 18_000_000_000, playCount: 1, isFavorite: false)
        )
        #expect(episode.timeCaption() == "60 min")
        #expect(episode.shelfFooterCaption() == "S1 · E2 · 60 min")
    }

    @Test("Episode shelf footer shows label only when playback is near end")
    func episodeShelfFooterNearEnd() {
        let episode = JellyfinFixtures.episode(
            name: "Pilot",
            seriesName: "Preview Show",
            indexNumber: 2,
            runtime: .seconds(3600),
            userData: UserItemData(played: false, playbackPositionTicks: 36_000_000_000, playCount: 0, isFavorite: false)
        )
        #expect(episode.shelfFooterCaption() == "S1 · E2")
        #expect(episode.shelfPlaybackProgress == 1.0)
    }

    // MARK: - imageRef availability per model
    //
    // Each model advertises a DIFFERENT subset of image kinds (a season has no logo, an episode
    // has only its own still). Getting a subset wrong shows up as a permanently blank tile, so
    // the supported AND unsupported kinds are both pinned, per model, as one table each.

    private static let allKinds: [ImageKind] = [
        .primary, .backdrop(index: 0), .logo, .thumb, .banner, .art, .disc,
    ]

    private func movie(withTags: Bool) -> Movie {
        JellyfinFixtures.movie(
            id: "m1",
            primaryTag: withTags ? ImageTag(rawValue: "p") : nil,
            backdropTags: withTags ? [ImageTag(rawValue: "b0"), ImageTag(rawValue: "b1")] : [],
            logoTag: withTags ? ImageTag(rawValue: "l") : nil,
            thumbTag: withTags ? ImageTag(rawValue: "th") : nil
        )
    }

    @Test(
        "Movie.imageRef resolves the kinds a movie carries",
        arguments: zip(allKinds, ["p", "b0", "l", "th", nil, nil, nil])
    )
    func movieImageRef(kind: ImageKind, expected: String?) {
        #expect(movie(withTags: true).imageRef(kind)?.tag.rawValue == expected)
    }

    @Test("Movie.imageRef returns nil for every kind when the tags are missing", arguments: allKinds)
    func movieImageRefWithoutTags(kind: ImageKind) {
        #expect(movie(withTags: false).imageRef(kind) == nil)
    }

    /// Backdrops are the one INDEXED kind, so an out-of-range index must read as absent rather
    /// than trap or wrap onto a neighbouring image.
    @Test("Movie backdrop indexing is bounds-checked")
    func movieBackdropIndexing() {
        #expect(movie(withTags: true).imageRef(.backdrop(index: 1))?.tag.rawValue == "b1")
        #expect(movie(withTags: true).imageRef(.backdrop(index: 5)) == nil)
    }

    @Test(
        "Series.imageRef supports primary/backdrop/logo/thumb/banner and nothing else",
        arguments: zip(allKinds, ["p", "b0", "l", "th", "bn", nil, nil])
    )
    func seriesImageRef(kind: ImageKind, expected: String?) {
        let series = Series(
            id: ItemID(rawValue: "s1"), title: "T",
            overview: nil, year: nil, status: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: ImageTag(rawValue: "p"),
            backdropTags: [ImageTag(rawValue: "b0")],
            logoTag: ImageTag(rawValue: "l"),
            thumbTag: ImageTag(rawValue: "th"),
            bannerTag: ImageTag(rawValue: "bn"),
            userData: .absent
        )
        #expect(series.imageRef(kind)?.tag.rawValue == expected)
    }

    @Test(
        "Season.imageRef supports only primary + thumb",
        arguments: zip(allKinds, ["p", nil, nil, "th", nil, nil, nil])
    )
    func seasonImageRef(kind: ImageKind, expected: String?) {
        let season = Season(
            id: ItemID(rawValue: "se1"), seriesID: ItemID(rawValue: "ser1"),
            name: "S1", indexNumber: 1,
            primaryTag: ImageTag(rawValue: "p"),
            thumbTag: ImageTag(rawValue: "th"),
            episodeCount: 7
        )
        #expect(season.imageRef(kind)?.tag.rawValue == expected)
    }

    @Test(
        "Episode.imageRef supports only its own still",
        arguments: zip(allKinds, ["p", nil, nil, nil, nil, nil, nil])
    )
    func episodeImageRef(kind: ImageKind, expected: String?) {
        let episode = JellyfinFixtures.episode(id: "e1", primaryTag: ImageTag(rawValue: "p"))
        #expect(episode.imageRef(kind)?.tag.rawValue == expected)
    }

    // MARK: - Quality badges

    @Test("QualityBadge resolution returns 4K only for UHD dimensions")
    func qualityBadgeResolution() {
        #expect(QualityBadge.resolution(width: 3840, height: 2160) == "4K")
        #expect(QualityBadge.resolution(width: 1920, height: 1080) == nil)
        #expect(QualityBadge.resolution(width: nil, height: nil) == nil)
    }

    /// Every HDR flavour collapses to one badge — including `DOVIInvalid`, which Jellyfin reports
    /// for a Dolby Vision profile it can't fully parse but which is still HDR content.
    @Test(
        "QualityBadge hdr collapses every HDR flavour and stays silent for SDR",
        arguments: zip(
            ["DOVI", "DOVIInvalid", "HDR10+", "HLG", "SDR", nil],
            ["HDR", "HDR", "HDR", "HDR", nil, nil]
        )
    )
    func qualityBadgeHDR(videoRangeType: String?, expected: String?) {
        #expect(QualityBadge.hdr(videoRangeType) == expected)
    }

    /// `Item` is what every shelf and grid holds, so its id has to resolve through whichever case
    /// wraps the model — a per-case miss would break selection and context menus for that kind only.
    @Test("Item exposes the wrapped model's id for every case")
    func itemID() {
        #expect(Item.movie(JellyfinFixtures.movie(id: "m")).id == ItemID(rawValue: "m"))
        #expect(Item.episode(JellyfinFixtures.episode(id: "e")).id == ItemID(rawValue: "e"))
        let series = Series(
            id: ItemID(rawValue: "s"), title: "S",
            overview: nil, year: nil, status: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil, bannerTag: nil,
            userData: .absent
        )
        #expect(Item.series(series).id == ItemID(rawValue: "s"))
    }
}

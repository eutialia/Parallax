import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("HomeHeroFeedBuilder")
struct HomeHeroFeedBuilderTests {
    /// The over-fetch has a floor (a bulk import can flood the batch, so a small carousel still
    /// needs a wide net) and a cap (the request is on the launch path). Both are the builder's own
    /// constants; only the ×4 scaling in between is stated here.
    @Test("The episode over-fetch is floored, scales, then caps")
    func episodeLatestFetchLimit() {
        let cap = HomeHeroFeedBuilder.episodeLatestFetchCap
        let floor = HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: 1)

        #expect(floor < cap, "the floor has to leave room to scale")
        // Below the floor's crossover, the floor wins.
        #expect(HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: 3) == floor)
        #expect(HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: floor / 4) == floor)
        // In between it scales with the presentation limit.
        let scaling = (floor / 4) + 1
        #expect(HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: scaling) == scaling * 4)
        // And it never exceeds the cap.
        #expect(HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: cap) == cap)
    }

    @Test("Bulk episode import without series date is NEWLY ADDED and plays S1E1")
    func bulkImportEyebrowAndPlay() {
        let base = Date(timeIntervalSince1970: 3_000_000)
        let items = (1...5).map { index in
            episode(
                id: "e\(index)",
                seriesID: "s1",
                season: 1,
                index: index,
                date: base.addingTimeInterval(Double(index))
            )
        }
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: nil)],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.count == 1)
        #expect(entries[0].eyebrow == .newlyAdded)
        #expect(entries[0].playTarget.id == ItemID(rawValue: "e1"))
    }

    @Test("Single episode without series date is NEW EPISODE AVAILABLE")
    func singleEpisodeWithoutSeriesDate() {
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "e9", seriesID: "s1", season: 1, index: 11, date: epDate)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: nil)],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries[0].eyebrow == .newEpisodeAvailable)
    }

    private func movie(id: String, date: Date, ticks: Int64 = 0) -> Item {
        .movie(JellyfinFixtures.movie(
            id: id,
            dateAdded: date,
            userData: UserItemData(played: false, playbackPositionTicks: ticks, playCount: 0, isFavorite: false)
        ))
    }

    private func episode(
        id: String, seriesID: String, season: Int, index: Int, date: Date,
        ticks: Int64 = 0
    ) -> Item {
        .episode(JellyfinFixtures.episode(
            id: id,
            seriesID: seriesID,
            seasonID: "sea-\(season)",
            name: "Ep \(id)",
            seriesName: "Series \(seriesID)",
            indexNumber: index,
            parentIndexNumber: season,
            dateAdded: date,
            userData: UserItemData(played: false, playbackPositionTicks: ticks, playCount: 0, isFavorite: false)
        ))
    }

    private func series(id: String, date: Date?) -> Series {
        Series(
            id: ItemID(rawValue: id), title: "Series \(id)", overview: nil, year: 2020,
            status: nil, communityRating: nil, officialRating: nil,
            genres: [], primaryTag: nil, backdropTags: [], logoTag: nil,
            thumbTag: nil, bannerTag: nil, dateAdded: date, userData: .absent
        )
    }

    @Test("Dedupes episodes to one entry per seriesId")
    func dedupe() {
        let d1 = Date(timeIntervalSince1970: 1_000_000)
        let d2 = Date(timeIntervalSince1970: 2_000_000)
        let latest = [
            episode(id: "e1", seriesID: "s1", season: 1, index: 1, date: d1),
            episode(id: "e2", seriesID: "s1", season: 1, index: 2, date: d2),
        ]
        let seriesByID = ["s1": series(id: "s1", date: d2)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: latest,
            seriesByID: seriesByID,
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.count == 1)
        #expect(entries[0].presentation.id == ItemID(rawValue: "s1"))
    }

    /// The eyebrow is a judgement about WHY something is on the hero: a series that landed in the
    /// same import window as its newest episode is new to the library, one that predates it just
    /// got another episode. Getting this wrong tells the user "NEWLY ADDED" about a show they've
    /// been watching for months.
    @Test(
        "The eyebrow follows how far the series predates its newest episode",
        arguments: [
            (0.0, HeroEyebrow.newlyAdded, "same import window"),
            (importWindowSeconds - 1, .newlyAdded, "just inside the window"),
            (importWindowSeconds + 1, .newEpisodeAvailable, "just outside the window"),
            (importWindowSeconds * 100, .newEpisodeAvailable, "long-established series"),
        ] as [(TimeInterval, HeroEyebrow, String)]
    )
    func eyebrowClassification(seriesAge: TimeInterval, expected: HeroEyebrow, label: String) {
        let episodeDate = Date(timeIntervalSince1970: 10_000_000)
        let items = [episode(id: "e1", seriesID: "s1", season: 1, index: 1, date: episodeDate)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: episodeDate.addingTimeInterval(-seriesAge))],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.first?.eyebrow == expected, "\(label) should read as \(expected)")
    }

    private static let importWindowSeconds = HomeHeroFeedBuilder.defaultImportWindow

    @Test("Cold series play target is S1E1 from batch")
    func playS1E1() {
        let d = Date(timeIntervalSince1970: 3_000_000)
        let items = [
            episode(id: "e12", seriesID: "s1", season: 1, index: 12, date: d),
            episode(id: "e1", seriesID: "s1", season: 1, index: 1, date: d),
        ]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: d)],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries[0].playTarget.id == ItemID(rawValue: "e1"))
    }

    /// A big import's Latest batch is truncated, so its earliest episode can sit mid-series. The
    /// start episode the repository fetched for that gap is what a newly added series plays.
    @Test(
        "A newly added series plays the fetched start episode, else the batch's earliest",
        arguments: [(fetched: true, expected: "e1"), (fetched: false, expected: "e4")]
    )
    func newlyAddedPlaysFetchedStartEpisode(fetched: Bool, expected: String) {
        let importedAt = Date(timeIntervalSince1970: 3_000_000)
        let items = (4...6).map { index in
            episode(id: "e\(index)", seriesID: "s1", season: 1, index: index, date: importedAt)
        }
        let start = JellyfinFixtures.episode(id: "e1", seriesID: "s1", indexNumber: 1, parentIndexNumber: 1)
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: importedAt)],
            firstEpisodeBySeriesID: fetched ? ["s1": start] : [:],
            limit: 12
        )
        #expect(entries.first?.eyebrow == .newlyAdded)
        #expect(entries.first?.playTarget.id == ItemID(rawValue: expected))
    }

    @Test("New episode play target is newest dateCreated in batch")
    func playLatestEpisode() {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let d1 = Date(timeIntervalSince1970: 4_000_000)
        let d2 = Date(timeIntervalSince1970: 5_000_000)
        let items = [
            episode(id: "e1", seriesID: "s1", season: 2, index: 1, date: d1),
            episode(id: "e2", seriesID: "s1", season: 2, index: 2, date: d2),
        ]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries[0].eyebrow == .newEpisodeAvailable)
        #expect(entries[0].playTarget.id == ItemID(rawValue: "e2"))
    }

    @Test("Movie passes through unchanged")
    func moviePassthrough() {
        let d = Date(timeIntervalSince1970: 2_000_000)
        let m = movie(id: "m1", date: d)
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [m],
            seriesByID: [:],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.count == 1)
        #expect(entries[0].eyebrow == .newlyAdded)
        #expect(entries[0].presentation == m)
        #expect(entries[0].playTarget == m)
    }

    @Test("NEWLY ADDED series in continue watching is excluded from hero")
    func excludeNewlyAddedSeriesInContinueWatching() {
        let d = Date(timeIntervalSince1970: 3_000_000)
        let items = [episode(id: "e1", seriesID: "s1", season: 1, index: 1, date: d)]
        let cw = [episode(id: "cw-e2", seriesID: "s1", season: 1, index: 2, date: d, ticks: 5_000_000_000)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: d)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            continueWatching: cw
        )
        #expect(entries.isEmpty)
    }

    @Test(
        "A NEW EPISODE hero stays only when it is the immediate next episode after Continue Watching",
        arguments: [
            (cw: (season: 1 as Int?, index: 11 as Int?), hero: (season: 1, index: 12), keeps: true),
            (cw: (season: 1, index: 12), hero: (season: 2, index: 1), keeps: true),
            (cw: (season: 1, index: 2), hero: (season: 1, index: 11), keeps: false),
            (cw: (season: nil, index: nil), hero: (season: 1, index: 1), keeps: false),
        ]
    )
    func continueWatchingGate(
        cw: (season: Int?, index: Int?),
        hero: (season: Int, index: Int),
        keeps: Bool
    ) {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "hero", seriesID: "s1", season: hero.season, index: hero.index, date: epDate)]
        let continueWatching = [Item.episode(JellyfinFixtures.episode(
            id: "cw",
            seriesID: "s1",
            indexNumber: cw.index,
            parentIndexNumber: cw.season,
            dateAdded: seriesDate,
            userData: UserItemData(played: false, playbackPositionTicks: 5_000_000_000, playCount: 0, isFavorite: false)
        ))]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            continueWatching: continueWatching
        )
        #expect(entries.map(\.playTarget.id) == (keeps ? [ItemID(rawValue: "hero")] : []))
        #expect(entries.allSatisfy { $0.eyebrow == .newEpisodeAvailable && $0.presentation.id == ItemID(rawValue: "s1") })
    }

    /// A series row in the Latest response is metadata, not a hero candidate — the hero presents a
    /// series only as the wrapper around a new EPISODE, so a bare series must contribute nothing.
    @Test("A bare series row in the batch produces no entry")
    func bareSeriesRowIsSkipped() {
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [.series(series(id: "s1", date: Date(timeIntervalSince1970: 3_000_000)))],
            seriesByID: ["s1": series(id: "s1", date: Date(timeIntervalSince1970: 3_000_000))],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.isEmpty)
    }

    /// An episode batch whose series metadata never arrived can't be presented (there'd be nothing
    /// to show as the hero's identity), so it's dropped rather than rendered half-built.
    @Test("Episodes whose series metadata is missing are dropped")
    func episodesWithoutSeriesMetadataAreDropped() {
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [episode(id: "e1", seriesID: "unknown", season: 1, index: 1, date: Date())],
            seriesByID: [:],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.isEmpty)
    }

    /// A movie with no `dateAdded` has nothing to sort the carousel by, so it can't be placed.
    @Test("A movie with no dateAdded is dropped")
    func movieWithoutDateIsDropped() {
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [.movie(JellyfinFixtures.movie(id: "m1", dateAdded: nil))],
            seriesByID: [:],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.isEmpty)
    }

    /// A newly added series is a premiere pitch, so it plays S1E1 even when its newest episode is
    /// part-watched.
    @Test("A newly added series plays S1E1 even when its newest episode is part-watched")
    func newlyAddedSeriesPlaysS1E1DespiteInProgressNewest() {
        let importedAt = Date(timeIntervalSince1970: 3_000_000)
        let items = [
            episode(id: "e1", seriesID: "s1", season: 1, index: 1, date: importedAt),
            episode(id: "e3", seriesID: "s1", season: 1, index: 3, date: importedAt.addingTimeInterval(10), ticks: 5_000_000_000),
        ]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: nil)],
            firstEpisodeBySeriesID: [:],
            limit: 12
        )
        #expect(entries.first?.eyebrow == .newlyAdded)
        #expect(entries.first?.playTarget.id == ItemID(rawValue: "e1"))
        #expect(entries.first?.playButtonTitle == "Play")
    }

    /// The carousel is newest-first and capped, so an over-long batch has to be truncated from the
    /// OLD end — dropping the newest arrivals would defeat the whole rail.
    @Test("Entries are ordered newest-first and truncated to the limit")
    func orderedNewestFirstAndLimited() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let movies = (0..<5).map { (offset: Int) in
            movie(id: "m\(offset)", date: base.addingTimeInterval(Double(offset) * 1_000))
        }
        let entries = HomeHeroFeedBuilder.build(
            latestItems: movies,
            seriesByID: [:],
            firstEpisodeBySeriesID: [:],
            limit: 3
        )
        #expect(entries.map(\.presentation.id) == [
            ItemID(rawValue: "m4"), ItemID(rawValue: "m3"), ItemID(rawValue: "m2"),
        ])
    }

    @Test("NEWLY ADDED movie in continue watching is excluded from hero")
    func excludeNewlyAddedMovieInContinueWatching() {
        let d = Date(timeIntervalSince1970: 2_000_000)
        let heroMovie = movie(id: "m1", date: d)
        let cwMovie = movie(id: "m1", date: d, ticks: 5_000_000_000)
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [heroMovie],
            seriesByID: [:],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            continueWatching: [cwMovie]
        )
        #expect(entries.isEmpty)
    }
}
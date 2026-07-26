import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("HomeHeroFeedBuilder")
struct HomeHeroFeedBuilderTests {
    private let importWindow: TimeInterval = HomeHeroFeedBuilder.defaultImportWindow

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
            limit: 12,
            importWindow: importWindow
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
            limit: 12,
            importWindow: importWindow
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
            limit: 12,
            importWindow: importWindow
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
            limit: 12,
            importWindow: importWindow
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
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries[0].playTarget.id == ItemID(rawValue: "e1"))
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
            limit: 12,
            importWindow: importWindow
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
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries.count == 1)
        #expect(entries[0].eyebrow == .newlyAdded)
        #expect(entries[0].presentation == m)
        #expect(entries[0].playTarget == m)
    }

    /// The button has to say what tapping it DOES. A partially watched movie resumes; an episode
    /// names which one it resumes so a series hero isn't ambiguous; anything unwatched just plays.
    @Test(
        "The play button names the action, and for an episode which episode",
        arguments: [
            (HeroTarget.movieInProgress, "Resume"),
            (.movieUnwatched, "Play"),
            (.episodeInProgress, "Resume S2 E3"),
            (.episodeUnwatched, "Play"),
        ]
    )
    func playButtonTitle(target: HeroTarget, expected: String) {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let itemDate = Date(timeIntervalSince1970: 5_000_000)
        let ticks: Int64 = target.isInProgress ? 5_000_000_000 : 0

        let entries: [HomeHeroFeedEntry]
        switch target {
        case .movieInProgress, .movieUnwatched:
            entries = HomeHeroFeedBuilder.build(
                latestItems: [movie(id: "m1", date: itemDate, ticks: ticks)],
                seriesByID: [:],
                firstEpisodeBySeriesID: [:],
                limit: 12,
                importWindow: importWindow
            )
        case .episodeInProgress, .episodeUnwatched:
            entries = HomeHeroFeedBuilder.build(
                latestItems: [episode(id: "e9", seriesID: "s1", season: 2, index: 3, date: itemDate, ticks: ticks)],
                seriesByID: ["s1": series(id: "s1", date: seriesDate)],
                firstEpisodeBySeriesID: [:],
                limit: 12,
                importWindow: importWindow
            )
        }
        #expect(entries.first?.playButtonTitle == expected)
    }

    enum HeroTarget: Sendable {
        case movieInProgress, movieUnwatched, episodeInProgress, episodeUnwatched

        var isInProgress: Bool {
            self == .movieInProgress || self == .episodeInProgress
        }
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
            continueWatching: cw,
            importWindow: importWindow
        )
        #expect(entries.isEmpty)
    }

    @Test("NEW EPISODE AVAILABLE series in continue watching stays on hero")
    func keepNewEpisodeAvailableSeriesInContinueWatching() {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "e12", seriesID: "s1", season: 1, index: 12, date: epDate)]
        let cw = [episode(id: "cw-e11", seriesID: "s1", season: 1, index: 11, date: seriesDate, ticks: 5_000_000_000)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            continueWatching: cw,
            importWindow: importWindow
        )
        #expect(entries.count == 1)
        #expect(entries[0].eyebrow == .newEpisodeAvailable)
        #expect(entries[0].presentation.id == ItemID(rawValue: "s1"))
        #expect(entries[0].playTarget.id == ItemID(rawValue: "e12"))
    }

    @Test("NEW EPISODE AVAILABLE cross-season premiere stays on hero when CW is season finale")
    func keepNewEpisodeAvailableCrossSeasonPremiere() {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "s2e1", seriesID: "s1", season: 2, index: 1, date: epDate)]
        let cw = [episode(id: "cw-e12", seriesID: "s1", season: 1, index: 12, date: seriesDate, ticks: 5_000_000_000)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            continueWatching: cw,
            importWindow: importWindow
        )
        #expect(entries.count == 1)
        #expect(entries[0].eyebrow == .newEpisodeAvailable)
        #expect(entries[0].playTarget.id == ItemID(rawValue: "s2e1"))
    }

    @Test("NEW EPISODE AVAILABLE is excluded when continue watching is far behind hero play")
    func excludeNewEpisodeAvailableWhenFarBehindContinueWatching() {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "e11", seriesID: "s1", season: 1, index: 11, date: epDate)]
        let cw = [episode(id: "cw-e2", seriesID: "s1", season: 1, index: 2, date: seriesDate, ticks: 5_000_000_000)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            continueWatching: cw,
            importWindow: importWindow
        )
        #expect(entries.isEmpty)
    }

    @Test("isSequentialNextUp matches same-season and next-season premieres")
    func sequentialNextUp() {
        let e2 = episode(id: "e2", seriesID: "s1", season: 1, index: 2, date: .distantPast)
        let e3 = episode(id: "e3", seriesID: "s1", season: 1, index: 3, date: .distantPast)
        let e11 = episode(id: "e11", seriesID: "s1", season: 1, index: 11, date: .distantPast)
        let s2e1 = episode(id: "s2e1", seriesID: "s1", season: 2, index: 1, date: .distantPast)
        guard case .episode(let e2ep) = e2, case .episode(let e3ep) = e3,
              case .episode(let e11ep) = e11, case .episode(let s2e1ep) = s2e1 else {
            Issue.record("expected episodes")
            return
        }
        #expect(HomeHeroFeedBuilder.isSequentialNextUp(from: e2ep, to: e3ep))
        #expect(!HomeHeroFeedBuilder.isSequentialNextUp(from: e2ep, to: e11ep))
        #expect(HomeHeroFeedBuilder.isSequentialNextUp(from: e11ep, to: s2e1ep))
        let s1finale = episode(id: "e12", seriesID: "s1", season: 1, index: 12, date: .distantPast)
        guard case .episode(let e12ep) = s1finale else { return }
        #expect(HomeHeroFeedBuilder.isSequentialNextUp(from: e11ep, to: e12ep))
        #expect(HomeHeroFeedBuilder.isSequentialNextUp(from: e12ep, to: s2e1ep))
    }

    /// A series row in the Latest response is metadata, not a hero candidate — the hero presents a
    /// series only as the wrapper around a new EPISODE, so a bare series must contribute nothing.
    @Test("A bare series row in the batch produces no entry")
    func bareSeriesRowIsSkipped() {
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [.series(series(id: "s1", date: Date(timeIntervalSince1970: 3_000_000)))],
            seriesByID: ["s1": series(id: "s1", date: Date(timeIntervalSince1970: 3_000_000))],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
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
            limit: 12,
            importWindow: importWindow
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
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries.isEmpty)
    }

    /// A part-watched newest episode wins the play target even for a newly-added series: the viewer
    /// is already mid-episode, and sending them back to S1E1 would throw that away.
    @Test("A part-watched newest episode is the play target even on a newly added series")
    func inProgressNewestWinsPlayTarget() {
        let importedAt = Date(timeIntervalSince1970: 3_000_000)
        let items = [
            episode(id: "e1", seriesID: "s1", season: 1, index: 1, date: importedAt),
            episode(id: "e3", seriesID: "s1", season: 1, index: 3, date: importedAt.addingTimeInterval(10), ticks: 5_000_000_000),
        ]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: nil)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
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
            limit: 3,
            importWindow: importWindow
        )
        #expect(entries.map(\.presentation.id) == [
            ItemID(rawValue: "m4"), ItemID(rawValue: "m3"), ItemID(rawValue: "m2"),
        ])
    }

    /// Adjacency is per SERIES: two shows' episode numbers must never chain into each other, or a
    /// hero would survive on a Continue Watching row from an unrelated show.
    @Test("Sequence adjacency never crosses series")
    func sequentialNextUpRequiresSameSeries() {
        guard case .episode(let showA) = episode(id: "a", seriesID: "s1", season: 1, index: 1, date: .distantPast),
              case .episode(let showB) = episode(id: "b", seriesID: "s2", season: 1, index: 2, date: .distantPast) else {
            Issue.record("expected episodes")
            return
        }
        #expect(HomeHeroFeedBuilder.isSequentialNextUp(from: showA, to: showB) == false)
    }

    /// Missing indices can't be compared, so adjacency has to answer "no" rather than guess.
    @Test("Sequence adjacency requires both indices on both episodes")
    func sequentialNextUpRequiresIndices() {
        let known = JellyfinFixtures.episode(id: "a", seriesID: "s1", indexNumber: 1, parentIndexNumber: 1)
        let indexless = JellyfinFixtures.episode(id: "b", seriesID: "s1", indexNumber: nil, parentIndexNumber: nil)
        #expect(HomeHeroFeedBuilder.isSequentialNextUp(from: known, to: indexless) == false)
        #expect(HomeHeroFeedBuilder.isSequentialNextUp(from: indexless, to: known) == false)
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
            continueWatching: [cwMovie],
            importWindow: importWindow
        )
        #expect(entries.isEmpty)
    }
}
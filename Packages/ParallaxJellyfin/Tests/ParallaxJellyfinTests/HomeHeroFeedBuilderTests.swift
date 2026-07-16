import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("HomeHeroFeedBuilder")
struct HomeHeroFeedBuilderTests {
    private let importWindow: TimeInterval = 24 * 60 * 60

    @Test("episode Latest over-fetch scales with presentation limit")
    func episodeLatestFetchLimit() {
        #expect(HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: 12) == 48)
        #expect(HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: 3) == 48)
        #expect(HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: 30) == 100)
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
        .movie(Movie(
            id: ItemID(rawValue: id), title: "Movie \(id)", overview: nil, year: 2024,
            runtime: nil, communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            dateAdded: date,
            userData: UserItemData(played: false, playbackPositionTicks: ticks, playCount: 0, isFavorite: false)
        ))
    }

    private func episode(
        id: String, seriesID: String, season: Int, index: Int, date: Date,
        ticks: Int64 = 0
    ) -> Item {
        .episode(Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesID),
            seasonID: ItemID(rawValue: "sea-\(season)"),
            name: "Ep \(id)",
            seriesName: "Series \(seriesID)",
            indexNumber: index,
            parentIndexNumber: season,
            overview: nil, runtime: nil, primaryTag: nil,
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

    @Test("NEWLY ADDED when series and newest episode share import window")
    func eyebrowNewSeries() {
        let d = Date(timeIntervalSince1970: 3_000_000)
        let items = [episode(id: "e1", seriesID: "s1", season: 1, index: 1, date: d)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: d)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries[0].eyebrow == .newlyAdded)
    }

    @Test("NEW EPISODE AVAILABLE when series predates newest episode")
    func eyebrowExistingSeries() {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "e9", seriesID: "s1", season: 2, index: 3, date: epDate)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries[0].eyebrow == .newEpisodeAvailable)
    }

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

    @Test("Movie with progress shows Resume play button title")
    func movieResumePlayButtonTitle() {
        let d = Date(timeIntervalSince1970: 2_000_000)
        let m = movie(id: "m1", date: d, ticks: 5_000_000_000)
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [m],
            seriesByID: [:],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries[0].playButtonTitle == "Resume")
    }

    @Test("Movie without progress shows Play play button title")
    func moviePlayPlayButtonTitle() {
        let d = Date(timeIntervalSince1970: 2_000_000)
        let m = movie(id: "m1", date: d)
        let entries = HomeHeroFeedBuilder.build(
            latestItems: [m],
            seriesByID: [:],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries[0].playButtonTitle == "Play")
    }

    @Test("Episode with progress shows Resume S# E# play button title")
    func episodeResumePlayButtonTitle() {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "e9", seriesID: "s1", season: 2, index: 3, date: epDate, ticks: 5_000_000_000)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries[0].playButtonTitle == "Resume S2 E3")
    }

    @Test("Episode without progress shows Play play button title")
    func episodePlayPlayButtonTitle() {
        let seriesDate = Date(timeIntervalSince1970: 1_000_000)
        let epDate = Date(timeIntervalSince1970: 5_000_000)
        let items = [episode(id: "e9", seriesID: "s1", season: 2, index: 3, date: epDate)]
        let entries = HomeHeroFeedBuilder.build(
            latestItems: items,
            seriesByID: ["s1": series(id: "s1", date: seriesDate)],
            firstEpisodeBySeriesID: [:],
            limit: 12,
            importWindow: importWindow
        )
        #expect(entries[0].playButtonTitle == "Play")
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
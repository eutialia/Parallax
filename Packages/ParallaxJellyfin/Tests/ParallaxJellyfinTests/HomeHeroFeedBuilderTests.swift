import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("HomeHeroFeedBuilder")
struct HomeHeroFeedBuilderTests {
    private let importWindow: TimeInterval = 24 * 60 * 60

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
            indexNumber: index,
            parentIndexNumber: season,
            overview: nil, runtime: nil, primaryTag: nil,
            dateAdded: date,
            userData: UserItemData(played: false, playbackPositionTicks: ticks, playCount: 0, isFavorite: false)
        ))
    }

    private func series(id: String, date: Date) -> Series {
        Series(
            id: ItemID(rawValue: id), title: "Series \(id)", overview: nil, year: 2020,
            status: nil, genres: [], primaryTag: nil, backdropTags: [], logoTag: nil,
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
}
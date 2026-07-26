import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DTO mapping")
struct DTOMappingTests {
    /// Decodes a captured server payload. `#require` rather than a force-unwrap so a renamed or
    /// missing fixture fails ONE test instead of trapping the whole suite.
    private func loadDto(_ name: String) throws -> BaseItemDto {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing test fixture Fixtures/\(name).json"
        )
        return try JSONDecoder().decode(BaseItemDto.self, from: try Data(contentsOf: url))
    }

    @Test("collection_movies.json → MediaCollection with .movies type")
    func collectionMovies() throws {
        let dto = try loadDto("collection_movies")
        let coll = dto.toMediaCollection()
        #expect(coll?.id.rawValue == "f137a2dd21bbc1b99aa5c0f6bf02a805")
        #expect(coll?.name == "Movies")
        #expect(coll?.collectionType == .movies)
        #expect(coll?.primaryTag?.rawValue == "abc123primary")
    }

    @Test("collection_tvshows.json → MediaCollection with .tvShows type and nil primary tag")
    func collectionTV() throws {
        let dto = try loadDto("collection_tvshows")
        let coll = dto.toMediaCollection()
        #expect(coll?.collectionType == .tvShows)
        #expect(coll?.primaryTag == nil)
    }

    @Test("movie.json → Movie with all fields populated")
    func movie() throws {
        let dto = try loadDto("movie")
        let m = dto.toMovie()
        #expect(m?.id.rawValue == "movie-uuid-1")
        #expect(m?.title == "The Matrix")
        #expect(m?.year == 1999)
        #expect(m?.runtime == .seconds(8178))   // 81_780_000_000 ticks / 10 = 8_178_000_000 µs = 8_178 s
        // Float→Double conversion introduces sub-epsilon error; compare with tolerance.
        #expect(abs((m?.communityRating ?? 0) - 8.7) < 0.001)
        #expect(m?.officialRating == "R")
        #expect(m?.genres == ["Action", "Science Fiction"])
        #expect(m?.primaryTag?.rawValue == "primary-tag-1")
        #expect(m?.backdropTags.map(\.rawValue) == ["backdrop-tag-1", "backdrop-tag-2"])
        #expect(m?.logoTag?.rawValue == "logo-tag-1")
        #expect(m?.thumbTag?.rawValue == "thumb-tag-1")
        #expect(m?.userData.isFavorite == true)
        #expect(m?.userData.playbackPositionTicks == 30_000_000_000)
    }

    @Test("series.json → Series with all fields populated")
    func series() throws {
        let dto = try loadDto("series")
        let s = dto.toSeries()
        #expect(s?.id.rawValue == "series-uuid-1")
        #expect(s?.title == "Breaking Bad")
        #expect(s?.year == 2008)
        #expect(s?.status == "Ended")
        #expect(s?.overview?.hasPrefix("A high school chemistry teacher") == true)
        #expect(s?.genres == ["Drama", "Crime"])
        #expect(s?.primaryTag?.rawValue == "series-primary-1")
        #expect(s?.logoTag?.rawValue == "series-logo-1")
        #expect(s?.thumbTag?.rawValue == "series-thumb-1")
        #expect(s?.bannerTag?.rawValue == "series-banner-1")
        #expect(s?.backdropTags.first?.rawValue == "series-backdrop-1")
        #expect(s?.userData.isFavorite == false)
    }

    @Test("Missing required fields cause every translator to return nil")
    func missingRequired() {
        var dto = BaseItemDto()
        dto.id = nil
        #expect(dto.toMovie() == nil)
        #expect(dto.toSeries() == nil)
        #expect(dto.toMediaCollection() == nil)
        dto.id = "x"
        dto.name = nil
        #expect(dto.toMovie() == nil)
        #expect(dto.toSeries() == nil)
        #expect(dto.toMediaCollection() == nil)
    }

    @Test("season.json → Season with seriesID linkage")
    func season() throws {
        let dto = try loadDto("season")
        let s = dto.toSeason()
        #expect(s?.id.rawValue == "season-uuid-1")
        #expect(s?.seriesID.rawValue == "series-uuid-1")
        #expect(s?.indexNumber == 1)
        #expect(s?.episodeCount == 7)
        #expect(s?.primaryTag?.rawValue == "season-primary-1")
    }

    @Test("episode.json → Episode with full parent linkage and played userData")
    func episode() throws {
        let dto = try loadDto("episode")
        let e = dto.toEpisode()
        #expect(e?.id.rawValue == "episode-uuid-1")
        #expect(e?.seriesID.rawValue == "series-uuid-1")
        #expect(e?.seasonID.rawValue == "season-uuid-1")
        #expect(e?.seriesName == "Breaking Bad")
        #expect(e?.indexNumber == 1)
        #expect(e?.parentIndexNumber == 1)
        // 34_020_000_000 ticks / 10 = 3_402_000_000 µs = 3_402 s
        #expect(e?.runtime == .seconds(3402))
        #expect(e?.userData.played == true)
        #expect(e?.userData.playCount == 1)
        #expect(e?.primaryTag?.rawValue == "episode-primary-1")
        #expect(e?.imageRef(.primary)?.tag.rawValue == "episode-primary-1")
        #expect(e?.seasonImageRef?.itemID.rawValue == "season-uuid-1")
        #expect(e?.seasonImageRef?.tag.rawValue == "season-primary-1")
        #expect(e?.seriesImageRef?.itemID.rawValue == "series-uuid-1")
        #expect(e?.seriesImageRef?.tag.rawValue == "series-primary-1")
        #expect(e?.seasonEpisodeLabel == "S1 · E1")
        #expect(e?.imageRef(.thumb) == nil)
    }

    @Test("movie_detail.json → ItemDetail.movie with tagline/studios/people populated")
    func movieDetail() throws {
        let dto = try loadDto("movie_detail")
        let detail = dto.toItemDetail()
        guard case .movie(let movieDetail) = detail else {
            Issue.record("expected .movie, got \(String(describing: detail))")
            return
        }
        #expect(movieDetail.movie.title == "The Matrix")
        #expect(movieDetail.tagline == "Welcome to the Real World.")
        #expect(movieDetail.studios == ["Warner Bros.", "Village Roadshow"])
        #expect(movieDetail.people.contains("Lana Wachowski"))
        #expect(movieDetail.people.contains("Keanu Reeves"))
        // Directors are extracted from the typed people list (`PersonKind.director`).
        #expect(movieDetail.directors == ["Lana Wachowski"])
    }

    /// Chapter mapping is shared by both detail branches, so it's asserted once per branch off one
    /// builder rather than twice over hand-copied DTOs. 100-ns ticks → `Duration`, in order, with
    /// the array position as the index.
    @Test("Chapters map in order with ticks converted, for every detail branch", arguments: [BaseItemKind.movie, .episode])
    func detailChapters(type: BaseItemKind) throws {
        var opening = ChapterInfo()
        opening.name = "Opening"
        opening.startPositionTicks = 0
        var second = ChapterInfo()
        second.name = "Act 2"
        second.startPositionTicks = 3_000_000_000       // /10 → 300_000_000 µs = 300 s

        let detail = try #require(chapterDto(type: type, chapters: [opening, second]).toItemDetail())
        let chapters = try #require(Self.chapters(of: detail))

        #expect(chapters.count == 2)
        #expect(chapters[0].index == 0)
        #expect(chapters[0].name == "Opening")
        #expect(chapters[0].start == .microseconds(0))
        #expect(chapters[1].index == 1)
        #expect(chapters[1].name == "Act 2")
        #expect(chapters[1].start == .seconds(300))
    }

    /// A chapter with no start offset can't be seeked to, so it's dropped rather than defaulted to
    /// zero (which would put a bogus marker at the head of the scrubber).
    @Test("A chapter with no start offset is dropped", arguments: [BaseItemKind.movie, .episode])
    func chapterNilTicksDropped(type: BaseItemKind) throws {
        var chapter = ChapterInfo()
        chapter.name = "No Ticks"
        chapter.startPositionTicks = nil

        let detail = try #require(chapterDto(type: type, chapters: [chapter]).toItemDetail())
        #expect(Self.chapters(of: detail)?.isEmpty == true)
    }

    /// `ItemDetail` carries chapters per case rather than on the enum, so the branch under test has
    /// to be unwrapped — and a case that shouldn't have chapters at all reads as nil, not empty.
    private static func chapters(of detail: ItemDetail) -> [Chapter]? {
        switch detail {
        case .movie(let d): d.chapters
        case .episode(let d): d.chapters
        case .series, .season: nil
        }
    }

    private func chapterDto(type: BaseItemKind, chapters: [ChapterInfo]) -> BaseItemDto {
        var dto = type == .movie
            ? JellyfinFixtures.movieDto(id: "movie-uuid-ch", name: "Chapters Movie")
            : JellyfinFixtures.episodeDto(id: "ep-uuid-ch", seriesID: "series-uuid-1", seasonID: "season-uuid-1")
        dto.chapters = chapters
        return dto
    }

    @Test("3840×2160 DOVI video stream → detailMetadata includes quality labels")
    func movieDetailMetadataQuality() {
        var dto = JellyfinFixtures.movieDto(id: "movie-badge-4k", name: "Badge Movie")
        dto.productionYear = 2020
        var stream = MediaStream()
        stream.type = .video
        stream.width = 3840
        stream.height = 2160
        stream.videoRangeType = .dovi
        dto.mediaStreams = [stream]
        let meta = dto.toMovie().map { DetailMetadata(movie: $0) }
        #expect(meta?.textParts == ["2020"])
        #expect(meta?.qualityLabels == ["4K", "HDR"])
    }

    @Test("No video stream → detailMetadata omits quality labels")
    func movieDetailMetadataNoStream() {
        var dto = JellyfinFixtures.movieDto(id: "movie-badge-empty", name: "No Stream Movie")
        dto.productionYear = 1999
        let meta = dto.toMovie().map { DetailMetadata(movie: $0) }
        #expect(meta?.textParts == ["1999"])
        #expect(meta?.qualityLabels.isEmpty == true)
    }

    @Test("Subtitle stream → hasSubtitles is true")
    func movieHasSubtitlesFromStream() {
        var sub = MediaStream()
        sub.type = .subtitle
        let dto = JellyfinFixtures.movieDto(id: "movie-subs", name: "Subtitled Movie", streams: [sub])
        #expect(dto.toMovie()?.hasSubtitles == true)
        #expect(dto.toMovie().map { DetailMetadata(movie: $0).hasSubtitles } == true)
    }

    @Test("hasSubtitles DTO flag without streams → hasSubtitles is true")
    func movieHasSubtitlesFromFlag() {
        var dto = JellyfinFixtures.movieDto(id: "movie-subs-flag", name: "Sidecar Subs Movie")
        dto.hasSubtitles = true
        let movie = dto.toMovie()
        #expect(movie?.hasSubtitles == true)
        #expect(movie.map { DetailMetadata(movie: $0).hasSubtitles } == true)
    }

    @Test("series maps communityRating and officialRating")
    func seriesRatings() {
        var dto = JellyfinFixtures.seriesDto(id: "series-rated", name: "Rated Show")
        dto.communityRating = 9.1
        dto.officialRating = "TV-MA"
        let series = dto.toSeries()
        let meta = series.map { DetailMetadata(series: $0) }
        #expect(abs((series?.communityRating ?? 0) - 9.1) < 0.001)
        #expect(series?.officialRating == "TV-MA")
        // A formatted-string expectation: the star glyph + one-decimal shape IS the spec the hero
        // renders, and `DetailMetadata`'s formatter is private, so the literal is the assertion.
        #expect(meta?.textParts.contains("★ 9.1") == true)
        #expect(meta?.textParts.contains("TV-MA") == true)
        #expect(meta?.qualityLabels.isEmpty == true)
        #expect(meta?.hasSubtitles == false)
    }

    /// `dateCreated` is what the hero feed's newly-added-vs-new-episode classification runs on, so
    /// every model that can appear there has to carry it through. Same mapping, three models.
    @Test(
        "dateCreated becomes dateAdded for every model the hero feed can present",
        arguments: [DatedModel.movie, .series, .episode]
    )
    func dateAddedMapping(model: DatedModel) throws {
        let fixed = try #require(ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z"))
        var dto = try loadDto(model.fixtureName)
        dto.dateCreated = fixed
        #expect(model.dateAdded(of: dto) == fixed)
    }

    enum DatedModel: Sendable {
        case movie, series, episode

        var fixtureName: String {
            switch self {
            case .movie: "movie"
            case .series: "series"
            case .episode: "episode"
            }
        }

        func dateAdded(of dto: BaseItemDto) -> Date? {
            switch self {
            case .movie: dto.toMovie()?.dateAdded
            case .series: dto.toSeries()?.dateAdded
            case .episode: dto.toEpisode()?.dateAdded
            }
        }
    }

    @Test("Unknown item type returns nil from toItemDetail")
    func unknownDetailType() {
        // Nil type → guard let type rejects.
        var dto = BaseItemDto()
        dto.id = "x"; dto.name = "x"; dto.type = nil
        #expect(dto.toItemDetail() == nil)

        // Known-but-unhandled type (e.g. .audio) → the switch's default arm rejects, so a music
        // item the server slipped into a response can't open a video detail screen.
        var audioDto = BaseItemDto()
        audioDto.id = "x"; audioDto.name = "x"; audioDto.type = .audio
        #expect(audioDto.toItemDetail() == nil)
    }
}

import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DTO mapping")
struct DTOMappingTests {
    private func loadDto(_ name: String) throws -> BaseItemDto {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BaseItemDto.self, from: data)
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
        #expect(e?.indexNumber == 1)
        #expect(e?.parentIndexNumber == 1)
        // 34_020_000_000 ticks / 10 = 3_402_000_000 µs = 3_402 s
        #expect(e?.runtime == .seconds(3402))
        #expect(e?.userData.played == true)
        #expect(e?.userData.playCount == 1)
        // Episodes carry their still under the natural `.primary` tag (16:9),
        // mapped identically to movies/series. This guards the Home row image
        // resolution path (Continue Watching / Next Up) against a regression
        // that drops the Primary tag — the only kind episodes expose.
        #expect(e?.primaryTag?.rawValue == "episode-primary-1")
        #expect(e?.imageRef(.primary)?.tag.rawValue == "episode-primary-1")
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
    }

    @Test("BaseItemDto with two chapters maps to MovieDetail with 2 Chapters (names + start offsets)")
    func movieDetailChapters() {
        var dto = BaseItemDto()
        dto.id = "movie-uuid-ch"
        dto.name = "Chapters Movie"
        dto.type = .movie
        var ch0 = ChapterInfo()
        ch0.name = "Opening"
        ch0.startPositionTicks = 0                  // 0 µs → .zero
        var ch1 = ChapterInfo()
        ch1.name = "Act 2"
        ch1.startPositionTicks = 3_000_000_000       // 300_000_000 µs = 300 s
        dto.chapters = [ch0, ch1]
        let detail = dto.toItemDetail()
        guard case .movie(let md) = detail else {
            Issue.record("expected .movie, got \(String(describing: detail))")
            return
        }
        #expect(md.chapters.count == 2)
        #expect(md.chapters[0].index == 0)
        #expect(md.chapters[0].name == "Opening")
        #expect(md.chapters[0].start == .microseconds(0))
        #expect(md.chapters[1].index == 1)
        #expect(md.chapters[1].name == "Act 2")
        // 3_000_000_000 ticks / 10 = 300_000_000 µs = 300 s
        #expect(md.chapters[1].start == .seconds(300))
    }

    @Test("Chapter with nil startPositionTicks is dropped from mapping")
    func chapterNilTicksDropped() {
        var dto = BaseItemDto()
        dto.id = "movie-uuid-ch2"
        dto.name = "Partial"
        dto.type = .movie
        var ch = ChapterInfo()
        ch.name = "No Ticks"
        ch.startPositionTicks = nil
        dto.chapters = [ch]
        let detail = dto.toItemDetail()
        guard case .movie(let md) = detail else {
            Issue.record("expected .movie, got \(String(describing: detail))")
            return
        }
        #expect(md.chapters.isEmpty)
    }

    @Test("BaseItemDto with two chapters maps to EpisodeDetail with 2 Chapters")
    func episodeDetailChapters() {
        var dto = BaseItemDto()
        dto.id = "ep-uuid-ch"
        dto.name = "Chapter Episode"
        dto.type = .episode
        dto.seriesID = "series-uuid-1"
        dto.seasonID = "season-uuid-1"
        var ch0 = ChapterInfo()
        ch0.name = "Intro"
        ch0.startPositionTicks = 0
        var ch1 = ChapterInfo()
        ch1.name = "Main"
        ch1.startPositionTicks = 900_000_000        // 90_000_000 µs = 90 s
        dto.chapters = [ch0, ch1]
        let detail = dto.toItemDetail()
        guard case .episode(let ed) = detail else {
            Issue.record("expected .episode, got \(String(describing: detail))")
            return
        }
        #expect(ed.chapters.count == 2)
        #expect(ed.chapters[1].name == "Main")
        #expect(ed.chapters[1].start == .seconds(90))
    }

    @Test("3840×2160 DOVI video stream → posterBadges == [\"4K\", \"Dolby Vision\"]")
    func moviePosterBadges4kDovi() {
        var dto = BaseItemDto()
        dto.id = "movie-badge-4k"
        dto.name = "Badge Movie"
        dto.type = .movie
        var stream = MediaStream()
        stream.type = .video
        stream.width = 3840
        stream.height = 2160
        stream.videoRangeType = .dovi
        dto.mediaStreams = [stream]
        let m = dto.toMovie()
        #expect(m?.posterBadges == ["4K", "Dolby Vision"])
    }

    @Test("No video stream → posterBadges == []")
    func moviePosterBadgesNoStream() {
        var dto = BaseItemDto()
        dto.id = "movie-badge-empty"
        dto.name = "No Stream Movie"
        dto.type = .movie
        dto.mediaStreams = nil
        let m = dto.toMovie()
        #expect(m?.posterBadges == [])
    }

    @Test("Unknown item type returns nil from toItemDetail")
    func unknownDetailType() {
        // Nil type → guard let type rejects
        var dto = BaseItemDto()
        dto.id = "x"; dto.name = "x"; dto.type = nil
        #expect(dto.toItemDetail() == nil)

        // Known-but-unhandled type (e.g. .audio) → switch's default arm rejects
        var audioDto = BaseItemDto()
        audioDto.id = "x"; audioDto.name = "x"; audioDto.type = .audio
        #expect(audioDto.toItemDetail() == nil)
    }
}

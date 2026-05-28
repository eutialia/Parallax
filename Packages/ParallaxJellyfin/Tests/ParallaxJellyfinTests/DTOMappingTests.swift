import Foundation
import Testing
import JellyfinAPI
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
        #expect(e?.userData.played == true)
        #expect(e?.userData.playCount == 1)
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

    @Test("Unknown item type returns nil from toItemDetail")
    func unknownDetailType() {
        var dto = BaseItemDto()
        dto.id = "x"
        dto.name = "x"
        dto.type = nil
        #expect(dto.toItemDetail() == nil)
    }
}

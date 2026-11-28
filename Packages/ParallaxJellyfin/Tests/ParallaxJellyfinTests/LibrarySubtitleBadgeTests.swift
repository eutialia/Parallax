import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import Testing

/// The subtitles badge on a film, from the library answers a Jellyfin server writes: a detail
/// lists the streams, a browse row carries only the `HasSubtitles` flag.
@Suite("Subtitles badge on a Jellyfin film")
struct LibrarySubtitleBadgeTests {

    /// The transport answers only while it lives, so the caller holds it.
    private static func repository(answering json: String) -> (LibraryRepository, StubHTTPTransport) {
        let stub = StubHTTPTransport()
        stub.always(.json(json))
        return (LibraryRepository(client: DefaultJellyfinLibraryClient(
            session: JellyfinFixtures.session(serverURL: stub.baseURL),
            identity: JellyfinFixtures.identity(),
            onTokenRejected: { _ in },
            sessionConfiguration: stub.configuration
        )), stub)
    }

    @Test("a film's detail shows the subtitles badge when one of its streams is a subtitle, and not otherwise",
          arguments: [(#", {"Index": 2, "Type": "Subtitle", "Codec": "subrip", "IsExternal": true}"#, true), ("", false)])
    func detailBadge(subtitleStream: String, badged: Bool) async throws {
        let (repository, transport) = Self.repository(answering: """
        {"TotalRecordCount": 1, "Items": [{"Id": "m1", "Name": "Heat", "Type": "Movie",
         "MediaStreams": [{"Index": 0, "Type": "Video", "Codec": "h264"}, {"Index": 1, "Type": "Audio", "Codec": "aac"}\(subtitleStream)]}]}
        """)

        guard case .movie(let detail) = try await repository.detail(for: ItemID(rawValue: "m1")) else {
            Issue.record("expected a movie detail")
            return
        }
        withExtendedLifetime(transport) {}
        #expect(DetailMetadata(movie: detail.movie).hasSubtitles == badged)
    }

    @Test("a film in a library row shows the subtitles badge from the server's flag alone, with no streams listed")
    func browseBadge() async throws {
        let (repository, transport) = Self.repository(answering: """
        {"TotalRecordCount": 2, "Items": [
            {"Id": "m2", "Name": "Ran", "Type": "Movie", "HasSubtitles": true},
            {"Id": "m3", "Name": "Kite", "Type": "Movie", "HasSubtitles": false}
        ]}
        """)

        let page = try await repository.items(
            in: .collection(CollectionID(rawValue: "films")), filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil)

        let badges = page.items.compactMap { item -> (String, Bool)? in
            guard case .movie(let movie) = item else { return nil }
            return (movie.title, DetailMetadata(movie: movie).hasSubtitles)
        }
        withExtendedLifetime(transport) {}
        #expect(badges.map(\.0) == ["Ran", "Kite"])
        #expect(badges.map(\.1) == [true, false])
    }
}

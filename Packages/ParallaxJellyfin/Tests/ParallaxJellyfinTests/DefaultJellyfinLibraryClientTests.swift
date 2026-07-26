import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

/// The SDK-backed browse client, driven over a stubbed transport (`StubHTTPTransport`) so the
/// REAL request is built and the REAL response decoded. Two things are under test in every case:
/// the endpoint + parameters the app sends (a wrong `parentId` or a dropped `fields` entry is a
/// silent behaviour change the fake-client repository tests cannot see), and the mapping of the
/// server's payload back into what `LibraryRepository` consumes.
@Suite("DefaultJellyfinLibraryClient — wire contract")
struct DefaultJellyfinLibraryClientTests {

    private func makeClient(
        stub: StubHTTPTransport,
        onTokenRejected: (@Sendable (ServerID) -> Void)? = nil
    ) -> DefaultJellyfinLibraryClient {
        DefaultJellyfinLibraryClient(
            session: JellyfinFixtures.session(id: "s1", token: "tok-1", serverURL: stub.baseURL, userID: "u1"),
            identity: JellyfinFixtures.identity(),
            onTokenRejected: onTokenRejected,
            sessionConfiguration: stub.configuration
        )
    }

    private func itemsPayload(_ items: [BaseItemDto], total: Int? = nil) -> StubHTTPTransport.Reply {
        .encoded(BaseItemDtoQueryResult(items: items, totalRecordCount: total ?? items.count))
    }

    // MARK: - Collections

    @Test("getCollections asks /UserViews for this user and returns the decoded items")
    func collections() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.collectionDto(id: "coll-1", name: "Movies")]))

        let dtos = try await makeClient(stub: stub).getCollections()

        let request = try stub.onlyExchange()
        #expect(request.method == "GET")
        #expect(request.path == "/UserViews")
        #expect(request.query("userId") == "u1")
        #expect(dtos.map(\.id) == ["coll-1"])
    }

    /// A body with no `Items` key at all — the server's shape for an empty result — must read as
    /// an empty library, never crash the browse surface.
    @Test("An Items-less payload decodes to an empty list rather than failing")
    func collectionsTolerateMissingItems() async throws {
        let stub = StubHTTPTransport()
        stub.always(.json("{}"))
        #expect(try await makeClient(stub: stub).getCollections().isEmpty)
    }

    // MARK: - Items (paging, scope, filter, sort)

    @Test("getItems pages a collection with the caller's window and the fixed browse field set")
    func itemsInCollection() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.movieDto(id: "m1")], total: 120))

        let result = try await makeClient(stub: stub).getItems(
            scope: .collection(CollectionID(rawValue: "coll-1")),
            filter: ItemFilter(),
            sort: .defaultForLibrary,
            startIndex: 50,
            limit: 50
        )

        let request = try stub.onlyExchange()
        #expect(request.path == "/Items")
        #expect(request.query("parentId") == "coll-1")
        #expect(request.query("startIndex") == "50")
        #expect(request.query("limit") == "50")
        #expect(request.query("recursive") == "true")
        #expect(request.query("imageTypeLimit") == "1")
        #expect(Set(request.queryValues("includeItemTypes")) == [BaseItemKind.movie.rawValue, BaseItemKind.series.rawValue])
        // No genre constraint was asked for, so the parameter must be absent — sending an empty
        // `genres` would filter everything out server-side.
        #expect(request.queryNames.contains("genres") == false)
        // Whole-set, not `.contains` — a spot-check would miss a dropped field surviving review.
        // This mirrors the exact list `getItems` sends today; update both sides together.
        #expect(Set(request.queryValues("fields")) == Set([ItemFields.primaryImageAspectRatio, .mediaSourceCount].map(\.rawValue)))
        #expect(Set(request.queryValues("enableImageTypes")) == Set([ImageType.primary, .backdrop, .logo, .thumb].map(\.rawValue)))
        #expect(result.total == 120)
        #expect(result.items.map(\.id) == ["m1"])
    }

    @Test("The favorites scope drops parentId and asks the server for the IsFavorite filter")
    func itemsInFavorites() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))

        _ = try await makeClient(stub: stub).getItems(
            scope: .favorites,
            filter: ItemFilter(),
            sort: .defaultForLibrary,
            startIndex: 0,
            limit: 50
        )

        let request = try stub.onlyExchange()
        #expect(request.queryNames.contains("parentId") == false)
        #expect(request.queryValues("filters") == [JellyfinAPI.ItemFilter.isFavorite.rawValue])
    }

    @Test("A genre filter is forwarded verbatim")
    func itemsForwardGenres() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))

        _ = try await makeClient(stub: stub).getItems(
            scope: .favorites,
            filter: ItemFilter(genres: ["Action", "Drama"]),
            sort: .defaultForLibrary,
            startIndex: 0,
            limit: 50
        )

        #expect(try stub.onlyExchange().queryValues("genres") == ["Action", "Drama"])
    }

    /// The domain→wire sort translation is a private extension with one arm per field; a wrong
    /// arm silently sorts the whole library by something else.
    @Test(
        "Each sort field maps to its Jellyfin sortBy value",
        arguments: zip(
            ItemSort.Field.allCases,
            [ItemSortBy.premiereDate, .dateCreated, .sortName, .communityRating, .officialRating]
        )
    )
    func sortFieldWireFormat(field: ItemSort.Field, expected: ItemSortBy) async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))

        _ = try await makeClient(stub: stub).getItems(
            scope: .favorites,
            filter: ItemFilter(),
            sort: ItemSort(field: field, direction: .descending),
            startIndex: 0,
            limit: 50
        )

        #expect(try stub.onlyExchange().queryValues("sortBy") == [expected.rawValue])
    }

    @Test(
        "Each sort direction maps to its Jellyfin sortOrder value",
        arguments: zip(ItemSort.Direction.allCases, [JellyfinAPI.SortOrder.ascending, .descending])
    )
    func sortDirectionWireFormat(direction: ItemSort.Direction, expected: JellyfinAPI.SortOrder) async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))

        _ = try await makeClient(stub: stub).getItems(
            scope: .favorites,
            filter: ItemFilter(),
            sort: ItemSort(field: .title, direction: direction),
            startIndex: 0,
            limit: 50
        )

        #expect(try stub.onlyExchange().queryValues("sortOrder") == [expected.rawValue])
    }

    // MARK: - Batch lookup

    @Test("getItemsByIDs short-circuits an empty id list without touching the network")
    func itemsByIDsEmpty() async throws {
        let stub = StubHTTPTransport()
        #expect(try await makeClient(stub: stub).getItemsByIDs([]).isEmpty)
        #expect(stub.exchanges.isEmpty, "an empty batch must not cost a request")
    }

    @Test("getItemsByIDs asks /Items for exactly the requested ids")
    func itemsByIDs() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.seasonDto(id: "se1"), JellyfinFixtures.seriesDto(id: "ser1")]))

        let dtos = try await makeClient(stub: stub).getItemsByIDs(["se1", "ser1"])

        let request = try stub.onlyExchange()
        #expect(request.path == "/Items")
        #expect(request.queryValues("ids") == ["se1", "ser1"])
        // Whole-set: mirrors the exact list `getItemsByIDs` sends today.
        #expect(Set(request.queryValues("fields")) == Set([ItemFields.overview, .primaryImageAspectRatio, .dateCreated].map(\.rawValue)))
        #expect(Set(request.queryValues("enableImageTypes")) == Set([ImageType.primary, .backdrop, .logo, .thumb].map(\.rawValue)))
        #expect(dtos.count == 2)
    }

    // MARK: - Detail

    /// A movie detail is two round-trips on purpose: `/Items` can't return chapters and media
    /// streams in one field list, and the second fetch is what the quality badges depend on.
    @Test("A movie detail merges a second media-streams fetch into the first response")
    func movieDetailMergesMediaStreams() async throws {
        let stub = StubHTTPTransport()
        var withStreams = JellyfinFixtures.movieDto(id: "m1")
        var video = MediaStream()
        video.type = .video
        video.codec = "hevc"
        withStreams.mediaStreams = [video]
        stub.enqueue(
            itemsPayload([JellyfinFixtures.movieDto(id: "m1")]),
            itemsPayload([withStreams])
        )

        let dto = try await makeClient(stub: stub).getItemDetail(itemID: "m1")

        let requests = stub.exchanges
        #expect(requests.count == 2)
        #expect(requests[0].queryValues("ids") == ["m1"])
        // Whole-set, not `.contains` — mirrors the exact list `getItemDetail`'s first fetch sends
        // today; a `.contains` spot-check would let a dropped field (e.g. `.people`) survive.
        #expect(
            Set(requests[0].queryValues("fields"))
                == Set([ItemFields.overview, .genres, .taglines, .studios, .people, .chapters].map(\.rawValue))
        )
        #expect(requests[1].queryValues("fields") == [ItemFields.mediaStreams.rawValue])
        #expect(dto.mediaStreams?.first?.codec == "hevc")
    }

    /// A series folder has no single video stream, so the heavy second fetch is skipped.
    @Test("A non-movie detail costs exactly one request")
    func seriesDetailSkipsMediaStreamFetch() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.seriesDto(id: "ser1")]))

        _ = try await makeClient(stub: stub).getItemDetail(itemID: "ser1")

        #expect(stub.exchanges.count == 1)
    }

    @Test("A detail response with no item throws rather than returning a hollow DTO")
    func detailWithNoItemThrows() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))
        await #expect(throws: AppError.self) {
            _ = try await makeClient(stub: stub).getItemDetail(itemID: "missing")
        }
    }

    // MARK: - Drill-in

    @Test("getSeasons hits the series' Seasons endpoint")
    func seasons() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.seasonDto(id: "se1", seriesID: "ser1")]))

        let dtos = try await makeClient(stub: stub).getSeasons(seriesID: "ser1")

        let request = try stub.onlyExchange()
        #expect(request.path == "/Shows/ser1/Seasons")
        #expect(request.query("userId") == "u1")
        #expect(dtos.map(\.id) == ["se1"])
    }

    /// Season folders can hold trailers and theme videos; without the type filter those would
    /// render as episodes in the season row.
    @Test("getEpisodes queries the season's children filtered to episodes, ordered by index")
    func episodes() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.episodeDto(id: "e1")]))

        _ = try await makeClient(stub: stub).getEpisodes(seasonID: "se1")

        let request = try stub.onlyExchange()
        #expect(request.path == "/Items")
        #expect(request.query("parentId") == "se1")
        #expect(request.queryValues("includeItemTypes") == [BaseItemKind.episode.rawValue])
        #expect(request.queryValues("sortBy") == [ItemSortBy.indexNumber.rawValue])
        #expect(request.queryValues("sortOrder") == [JellyfinAPI.SortOrder.ascending.rawValue])
    }

    // MARK: - Home shelves

    @Test("getContinueWatching asks the resume endpoint for video items only")
    func continueWatching() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.movieDto(id: "m1")]))

        let dtos = try await makeClient(stub: stub).getContinueWatching()

        let request = try stub.onlyExchange()
        #expect(request.path == "/UserItems/Resume")
        #expect(request.query("limit") == "12")
        #expect(request.queryValues("mediaTypes") == [MediaType.video.rawValue])
        // Whole-set: mirrors the exact list `getContinueWatching` sends today.
        #expect(Set(request.queryValues("fields")) == Set([ItemFields.primaryImageAspectRatio, .mediaSourceCount].map(\.rawValue)))
        #expect(Set(request.queryValues("enableImageTypes")) == Set([ImageType.primary, .backdrop, .thumb].map(\.rawValue)))
        #expect(dtos.count == 1)
    }

    @Test("getNextUp asks the NextUp shelf endpoint")
    func nextUp() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.episodeDto(id: "e1")]))

        let dtos = try await makeClient(stub: stub).getNextUp()

        let request = try stub.onlyExchange()
        #expect(request.path == "/Shows/NextUp")
        #expect(request.query("limit") == "12")
        #expect(request.queryNames.contains("seriesId") == false)
        // Whole-set: mirrors the exact list `getNextUp` sends today.
        #expect(Set(request.queryValues("fields")) == Set([ItemFields.primaryImageAspectRatio].map(\.rawValue)))
        #expect(Set(request.queryValues("enableImageTypes")) == Set([ImageType.primary, .backdrop, .thumb].map(\.rawValue)))
        #expect(dtos.count == 1)
    }

    /// `/Items/Latest` answers a BARE array, not a query-result envelope — a decoding shape the
    /// envelope-based endpoints don't exercise.
    @Test("getRecentlyAdded decodes the bare Latest array and forwards limit + types")
    func recentlyAdded() async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded([JellyfinFixtures.movieDto(id: "m1"), JellyfinFixtures.movieDto(id: "m2")]))

        let dtos = try await makeClient(stub: stub).getRecentlyAdded(limit: 48, includeItemTypes: [.episode])

        let request = try stub.onlyExchange()
        #expect(request.path == "/Items/Latest")
        #expect(request.query("limit") == "48")
        #expect(request.queryValues("includeItemTypes") == [BaseItemKind.episode.rawValue])
        // Grouping would collapse a series' new episodes into one row and defeat the hero feed.
        #expect(request.query("groupItems") == "false")
        #expect(request.query("enableUserData") == "true")
        // Whole-set: mirrors the exact list `getRecentlyAdded` sends today.
        #expect(Set(request.queryValues("fields")) == Set([ItemFields.overview, .primaryImageAspectRatio, .dateCreated].map(\.rawValue)))
        #expect(Set(request.queryValues("enableImageTypes")) == Set([ImageType.primary, .backdrop, .logo, .thumb].map(\.rawValue)))
        #expect(dtos.count == 2)
    }

    @Test("seriesNextUp asks for a single episode scoped to the series")
    func seriesNextUp() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.episodeDto(id: "e5", seriesID: "ser1")]))

        let dto = try await makeClient(stub: stub).seriesNextUp(seriesID: "ser1")

        let request = try stub.onlyExchange()
        #expect(request.path == "/Shows/NextUp")
        #expect(request.query("seriesId") == "ser1")
        #expect(request.query("limit") == "1")
        // Whole-set: mirrors the exact list `seriesNextUp` sends today.
        #expect(Set(request.queryValues("fields")) == Set([ItemFields.overview, .primaryImageAspectRatio].map(\.rawValue)))
        #expect(Set(request.queryValues("enableImageTypes")) == Set([ImageType.primary, .backdrop, .thumb].map(\.rawValue)))
        #expect(dto?.id == "e5")
    }

    @Test("seriesNextUp reports nil for a series with nothing queued")
    func seriesNextUpEmpty() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))
        #expect(try await makeClient(stub: stub).seriesNextUp(seriesID: "ser1") == nil)
    }

    // MARK: - Search

    /// The private scope→types translation decides which item kinds a scoped search can return;
    /// a wrong arm makes a whole tab permanently empty.
    @Test(
        "Each search scope narrows includeItemTypes",
        arguments: zip(
            SearchScope.allCases,
            [
                [BaseItemKind.movie, .series, .episode],
                [BaseItemKind.movie],
                [BaseItemKind.series],
                [BaseItemKind.episode],
            ]
        )
    )
    func searchScopeTypes(scope: SearchScope, expected: [BaseItemKind]) async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))

        _ = try await makeClient(stub: stub).search(query: "bad", scope: scope)

        let request = try stub.onlyExchange()
        #expect(request.path == "/Items")
        #expect(request.query("searchTerm") == "bad")
        #expect(request.query("limit") == "50")
        #expect(request.query("recursive") == "true")
        #expect(request.queryValues("includeItemTypes") == expected.map(\.rawValue))
    }

    // MARK: - User-data writes

    @Test("setFavorite POSTs to add and DELETEs to remove", arguments: [true, false])
    func setFavorite(isFavorite: Bool) async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded(UserItemDataDto(isFavorite: isFavorite, isPlayed: false, playCount: 2)))

        let data = try await makeClient(stub: stub).setFavorite(itemID: "item-42", isFavorite: isFavorite)

        let request = try stub.onlyExchange()
        #expect(request.path == "/UserFavoriteItems/item-42")
        #expect(request.method == (isFavorite ? "POST" : "DELETE"))
        #expect(request.query("userId") == "u1")
        // The server's answer is the source of truth — the client must return what came back,
        // not echo the flag it sent.
        #expect(data.isFavorite == isFavorite)
        #expect(data.playCount == 2)
    }

    @Test("setPlayed POSTs to mark and DELETEs to unmark", arguments: [true, false])
    func setPlayed(isPlayed: Bool) async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded(UserItemDataDto(isPlayed: isPlayed, playCount: 1, playbackPositionTicks: 900)))

        let data = try await makeClient(stub: stub).setPlayed(itemID: "item-7", isPlayed: isPlayed)

        let request = try stub.onlyExchange()
        #expect(request.path == "/UserPlayedItems/item-7")
        #expect(request.method == (isPlayed ? "POST" : "DELETE"))
        #expect(data.played == isPlayed)
        #expect(data.playbackPositionTicks == 900)
    }

    // MARK: - Segments & adjacency

    @Test("mediaSegments asks only for the kinds the player can act on")
    func mediaSegments() async throws {
        let stub = StubHTTPTransport()
        var segment = MediaSegmentDto()
        segment.id = "seg-1"
        segment.type = .intro
        segment.startTicks = 0
        segment.endTicks = 300_000_000
        stub.always(.encoded(MediaSegmentDtoQueryResult(items: [segment])))

        let dtos = try await makeClient(stub: stub).mediaSegments(itemID: "item-1")

        let request = try stub.onlyExchange()
        #expect(request.path == "/MediaSegments/item-1")
        #expect(
            Set(request.queryValues("includeSegmentTypes"))
                == Set([MediaSegmentType.intro, .recap, .outro].map(\.rawValue))
        )
        #expect(dtos.map(\.id) == ["seg-1"])
    }

    /// No season filter on purpose: the window has to cross a season boundary so a finale can
    /// hand off to the next premiere.
    @Test("adjacentEpisodes asks the series-wide episode window around one episode")
    func adjacentEpisodes() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([JellyfinFixtures.episodeDto(id: "e1"), JellyfinFixtures.episodeDto(id: "e2")]))

        let dtos = try await makeClient(stub: stub).adjacentEpisodes(seriesID: "ser1", episodeID: "e1")

        let request = try stub.onlyExchange()
        #expect(request.path == "/Shows/ser1/Episodes")
        #expect(request.query("adjacentTo") == "e1")
        #expect(request.queryNames.contains("seasonId") == false)
        #expect(request.query("enableUserData") == "true")
        // Whole-set: mirrors the exact list `adjacentEpisodes` sends today.
        #expect(Set(request.queryValues("fields")) == Set([ItemFields.overview, .primaryImageAspectRatio].map(\.rawValue)))
        #expect(Set(request.queryValues("enableImageTypes")) == Set([ImageType.primary, .backdrop, .thumb].map(\.rawValue)))
        #expect(dtos.count == 2)
    }

    // MARK: - Genres

    @Test("genres in a collection scope are parented to that collection")
    func genresInCollection() async throws {
        let stub = StubHTTPTransport()
        var action = BaseItemDto()
        action.name = "Action"
        var unnamed = BaseItemDto()
        unnamed.id = "no-name"
        stub.always(itemsPayload([action, unnamed]))

        let genres = try await makeClient(stub: stub).genres(scope: .collection(CollectionID(rawValue: "coll-1")))

        let request = try stub.onlyExchange()
        #expect(request.path == "/Genres")
        #expect(request.query("parentId") == "coll-1")
        // A nameless genre row is unusable in a filter menu, so it's dropped rather than shown blank.
        #expect(genres == ["Action"])
    }

    @Test("genres in the favorites scope switch to the isFavorite filter")
    func genresInFavorites() async throws {
        let stub = StubHTTPTransport()
        stub.always(itemsPayload([]))

        _ = try await makeClient(stub: stub).genres(scope: .favorites)

        let request = try stub.onlyExchange()
        #expect(request.query("isFavorite") == "true")
        #expect(request.queryNames.contains("parentId") == false)
    }

    // MARK: - Token rejection wiring

    /// The validator is installed on this client, so a 401 anywhere in browse traffic is what
    /// turns a revoked token into a signed-out server. Without the delegate hookup the same 401
    /// would surface as a generic server error and the row would keep looking connected.
    @Test("A 401 from any browse call reports the rejected token and names the expiry")
    func unauthorizedReportsTokenRejection() async throws {
        let stub = StubHTTPTransport()
        stub.always(.json("{}", status: 401))
        let reported = ReportedServerIDs()
        let client = makeClient(stub: stub, onTokenRejected: { reported.record($0) })

        do {
            _ = try await client.getCollections()
            Issue.record("a 401 must not resolve successfully")
        } catch let error as AppError {
            guard case .auth(.tokenInvalidated) = error else {
                Issue.record("expected .auth(.tokenInvalidated), got \(error)")
                return
            }
        }
        #expect(reported.ids == [ServerID(rawValue: "s1")])
    }

    @Test("Without a rejection sink a 401 is still an error, and nothing is reported")
    func unauthorizedWithoutSink() async throws {
        let stub = StubHTTPTransport()
        stub.always(.json("{}", status: 401))
        // No delegate installed → the SDK's own 2xx check throws its APIError instead.
        await #expect(throws: (any Error).self) {
            _ = try await makeClient(stub: stub).getCollections()
        }
    }
}

/// Collects ids across the validator's `@Sendable` callback boundary.
final class ReportedServerIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ServerID] = []
    var ids: [ServerID] { lock.withLock { storage } }
    func record(_ id: ServerID) { lock.withLock { storage.append(id) } }
}

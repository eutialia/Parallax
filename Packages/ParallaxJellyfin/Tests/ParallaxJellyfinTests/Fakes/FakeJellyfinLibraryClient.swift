import Foundation
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

final class FakeJellyfinLibraryClient: JellyfinLibraryClient, @unchecked Sendable {
    // Programmable hooks — each Result is reused per call (unlike the
    // one-shot pattern in FakeJellyfinAuthClient — repository tests can
    // call the same method multiple times in one test).
    var collectionsResult: Result<[BaseItemDto], Error> = .success([])
    var itemsResult: Result<(items: [BaseItemDto], total: Int), Error> = .success(([], 0))
    var itemsPagedResults: [Result<(items: [BaseItemDto], total: Int), Error>] = []  // consumed in order
    var detailResult: Result<BaseItemDto, Error> = .failure(FakeError.notConfigured)
    var itemsByIDsResult: Result<[BaseItemDto], Error> = .success([])
    var seasonsResult: Result<[BaseItemDto], Error> = .success([])
    var episodesResult: Result<[BaseItemDto], Error> = .success([])
    var continueWatchingResult: Result<[BaseItemDto], Error> = .success([])
    var nextUpResult: Result<[BaseItemDto], Error> = .success([])
    var recentlyAddedResult: Result<[BaseItemDto], Error> = .success([])
    var recentlyAddedResultsByTypes: [BaseItemKind: Result<[BaseItemDto], Error>] = [:]
    var searchResult: Result<[BaseItemDto], Error> = .success([])
    // Per-scope override — used by tests that need to verify the repository
    // routes per-type searches independently (scope .all fans out into three
    // parallel calls). Falls back to `searchResult` if a scope is unmapped.
    var searchResultsByScope: [SearchScope: Result<[BaseItemDto], Error>] = [:]
    var seriesNextUpResult: Result<BaseItemDto?, Error> = .success(nil)
    var mediaSegmentsResult: Result<[MediaSegmentDto], Error> = .success([])
    var adjacentEpisodesResult: Result<[BaseItemDto], Error> = .success([])
    var genresResult: Result<[String], Error> = .success([])
    var setFavoriteResult: Result<UserItemData, Error> = .success(
        UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
    )
    var setPlayedResult: Result<UserItemData, Error> = .success(
        UserItemData(played: true, playbackPositionTicks: 0, playCount: 1, isFavorite: false)
    )

    // Call records.
    private(set) var collectionsCallCount = 0
    private(set) var itemsCalls: [(scope: LibraryScope, filter: ParallaxCore.ItemFilter, sort: ParallaxCore.ItemSort, startIndex: Int, limit: Int)] = []
    private(set) var detailCalls: [String] = []
    private(set) var itemsByIDsCalls: [[String]] = []
    private(set) var seasonsCalls: [String] = []
    private(set) var episodesCalls: [String] = []
    private(set) var continueWatchingCallCount = 0
    private(set) var nextUpCallCount = 0
    private(set) var recentlyAddedCalls: [(limit: Int, types: [BaseItemKind])] = []
    private(set) var searchCalls: [(query: String, scope: SearchScope)] = []
    private(set) var setFavoriteCalls: [(itemID: String, isFavorite: Bool)] = []
    private(set) var setPlayedCalls: [(itemID: String, isPlayed: Bool)] = []
    private(set) var seriesNextUpCalls: [String] = []
    private(set) var mediaSegmentsCalls: [String] = []
    private(set) var adjacentEpisodesCalls: [(seriesID: String, episodeID: String)] = []
    private(set) var genresCalls: [LibraryScope] = []

    enum FakeError: Error { case notConfigured }

    func getCollections() async throws -> [BaseItemDto] {
        collectionsCallCount += 1
        return try collectionsResult.get()
    }

    func getItems(scope: LibraryScope, filter: ParallaxCore.ItemFilter, sort: ParallaxCore.ItemSort, startIndex: Int, limit: Int) async throws -> (items: [BaseItemDto], total: Int) {
        itemsCalls.append((scope, filter, sort, startIndex, limit))
        if !itemsPagedResults.isEmpty {
            let result = itemsPagedResults.removeFirst()
            return try result.get()
        }
        return try itemsResult.get()
    }

    func getItemDetail(itemID: String) async throws -> BaseItemDto {
        detailCalls.append(itemID)
        return try detailResult.get()
    }

    func getItemsByIDs(_ ids: [String]) async throws -> [BaseItemDto] {
        itemsByIDsCalls.append(ids)
        return try itemsByIDsResult.get()
    }

    func getSeasons(seriesID: String) async throws -> [BaseItemDto] {
        seasonsCalls.append(seriesID)
        return try seasonsResult.get()
    }

    func getEpisodes(seasonID: String) async throws -> [BaseItemDto] {
        episodesCalls.append(seasonID)
        return try episodesResult.get()
    }

    func getContinueWatching() async throws -> [BaseItemDto] {
        continueWatchingCallCount += 1
        return try continueWatchingResult.get()
    }

    func getNextUp() async throws -> [BaseItemDto] {
        nextUpCallCount += 1
        return try nextUpResult.get()
    }

    func getRecentlyAdded(limit: Int, includeItemTypes: [BaseItemKind]) async throws -> [BaseItemDto] {
        recentlyAddedCalls.append((limit, includeItemTypes))
        if includeItemTypes.count == 1, let type = includeItemTypes.first,
           let perType = recentlyAddedResultsByTypes[type] {
            return try perType.get()
        }
        return try recentlyAddedResult.get()
    }

    func search(query: String, scope: SearchScope) async throws -> [BaseItemDto] {
        searchCalls.append((query, scope))
        if let perScope = searchResultsByScope[scope] {
            return try perScope.get()
        }
        return try searchResult.get()
    }

    func setFavorite(itemID: String, isFavorite: Bool) async throws -> UserItemData {
        setFavoriteCalls.append((itemID: itemID, isFavorite: isFavorite))
        let resolved = try setFavoriteResult.get()
        return UserItemData(
            played: resolved.played,
            playbackPositionTicks: resolved.playbackPositionTicks,
            playCount: resolved.playCount,
            isFavorite: isFavorite
        )
    }

    func setPlayed(itemID: String, isPlayed: Bool) async throws -> UserItemData {
        setPlayedCalls.append((itemID: itemID, isPlayed: isPlayed))
        return try setPlayedResult.get()
    }

    func seriesNextUp(seriesID: String) async throws -> BaseItemDto? {
        seriesNextUpCalls.append(seriesID)
        return try seriesNextUpResult.get()
    }

    func mediaSegments(itemID: String) async throws -> [MediaSegmentDto] {
        mediaSegmentsCalls.append(itemID)
        return try mediaSegmentsResult.get()
    }

    func adjacentEpisodes(seriesID: String, episodeID: String) async throws -> [BaseItemDto] {
        adjacentEpisodesCalls.append((seriesID, episodeID))
        return try adjacentEpisodesResult.get()
    }

    func genres(scope: LibraryScope) async throws -> [String] {
        genresCalls.append(scope)
        return try genresResult.get()
    }
}

final class FakeJellyfinLibraryClientFactory: JellyfinLibraryClientFactory, @unchecked Sendable {
    private var clientsBySession: [ServerID: FakeJellyfinLibraryClient] = [:]
    private(set) var makeCalls: [ServerID] = []

    func client(for session: Session) -> FakeJellyfinLibraryClient {
        if let existing = clientsBySession[session.id] { return existing }
        let new = FakeJellyfinLibraryClient()
        clientsBySession[session.id] = new
        return new
    }

    func make(for session: Session) async -> JellyfinLibraryClient {
        makeCalls.append(session.id)
        return client(for: session)
    }
}

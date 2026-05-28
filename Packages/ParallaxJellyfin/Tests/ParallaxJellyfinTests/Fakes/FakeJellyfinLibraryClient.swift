import Foundation
import JellyfinAPI
@testable import ParallaxJellyfin

final class FakeJellyfinLibraryClient: JellyfinLibraryClient, @unchecked Sendable {
    // Programmable hooks — each Result is reused per call (unlike the
    // one-shot pattern in FakeJellyfinAuthClient — repository tests can
    // call the same method multiple times in one test).
    var collectionsResult: Result<[BaseItemDto], Error> = .success([])
    var itemsResult: Result<(items: [BaseItemDto], total: Int), Error> = .success(([], 0))
    var itemsPagedResults: [Result<(items: [BaseItemDto], total: Int), Error>] = []  // consumed in order
    var detailResult: Result<BaseItemDto, Error> = .failure(FakeError.notConfigured)
    var seasonsResult: Result<[BaseItemDto], Error> = .success([])
    var episodesResult: Result<[BaseItemDto], Error> = .success([])
    var continueWatchingResult: Result<[BaseItemDto], Error> = .success([])
    var nextUpResult: Result<[BaseItemDto], Error> = .success([])
    var searchResult: Result<[BaseItemDto], Error> = .success([])
    // Per-scope override — used by tests that need to verify the repository
    // routes per-type searches independently (scope .all fans out into three
    // parallel calls). Falls back to `searchResult` if a scope is unmapped.
    var searchResultsByScope: [SearchScope: Result<[BaseItemDto], Error>] = [:]

    // Call records.
    private(set) var collectionsCallCount = 0
    private(set) var itemsCalls: [(parentID: String, filter: ParallaxJellyfin.ItemFilter, sort: ParallaxJellyfin.ItemSort, startIndex: Int, limit: Int)] = []
    private(set) var detailCalls: [String] = []
    private(set) var seasonsCalls: [String] = []
    private(set) var episodesCalls: [String] = []
    private(set) var continueWatchingCallCount = 0
    private(set) var nextUpCallCount = 0
    private(set) var searchCalls: [(query: String, scope: SearchScope)] = []

    enum FakeError: Error { case notConfigured }

    func getCollections() async throws -> [BaseItemDto] {
        collectionsCallCount += 1
        return try collectionsResult.get()
    }

    func getItems(parentID: String, filter: ParallaxJellyfin.ItemFilter, sort: ParallaxJellyfin.ItemSort, startIndex: Int, limit: Int) async throws -> (items: [BaseItemDto], total: Int) {
        itemsCalls.append((parentID, filter, sort, startIndex, limit))
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

    func search(query: String, scope: SearchScope) async throws -> [BaseItemDto] {
        searchCalls.append((query, scope))
        if let perScope = searchResultsByScope[scope] {
            return try perScope.get()
        }
        return try searchResult.get()
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

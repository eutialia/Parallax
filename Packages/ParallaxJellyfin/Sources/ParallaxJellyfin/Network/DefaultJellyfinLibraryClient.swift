import Foundation
import JellyfinAPI

public final class DefaultJellyfinLibraryClient: JellyfinLibraryClient, @unchecked Sendable {
    private let session: Session
    private let identity: DeviceIdentity

    public init(session: Session, identity: DeviceIdentity) {
        self.session = session
        self.identity = identity
    }

    private func client() -> JellyfinClient {
        let config = JellyfinClient.Configuration(
            url: session.serverURL,
            accessToken: session.accessToken,
            client: identity.client,
            deviceName: identity.deviceName,
            deviceID: identity.deviceID,
            version: identity.version
        )
        return JellyfinClient(configuration: config)
    }

    private var userID: String { session.user.id }

    // MARK: - JellyfinLibraryClient

    public func getCollections() async throws -> [BaseItemDto] {
        var params = Paths.GetUserViewsParameters()
        params.userID = userID
        let request = Paths.getUserViews(parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func getItems(
        parentID: String,
        filter: ItemFilter,
        sort: ItemSort,
        startIndex: Int,
        limit: Int
    ) async throws -> (items: [BaseItemDto], total: Int) {
        var params = Paths.GetItemsParameters()
        params.userID = userID
        params.parentID = parentID
        params.startIndex = startIndex
        params.limit = limit
        params.isRecursive = true
        params.sortBy = [sort.wireFormat]
        params.sortOrder = [sort.direction.wireFormat]
        params.fields = [.primaryImageAspectRatio, .mediaSourceCount]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .logo, .thumb]
        params.filters = filter.wireFormat
        params.isFavorite = filter.favoritesOnly ? true : nil
        params.includeItemTypes = [.movie, .series]

        let request = Paths.getItems(parameters: params)
        let response = try await client().send(request)
        return (response.value.items ?? [], response.value.totalRecordCount ?? 0)
    }

    public func getItemDetail(itemID: String) async throws -> BaseItemDto {
        let request = Paths.getItem(itemID: itemID, userID: userID)
        return try await client().send(request).value
    }

    public func getSeasons(seriesID: String) async throws -> [BaseItemDto] {
        var params = Paths.GetSeasonsParameters()
        params.userID = userID
        params.fields = [.primaryImageAspectRatio]
        let request = Paths.getSeasons(seriesID: seriesID, parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func getEpisodes(seasonID: String) async throws -> [BaseItemDto] {
        // Episodes queried via /Items with parentId = seasonID, sorted by index.
        var params = Paths.GetItemsParameters()
        params.userID = userID
        params.parentID = seasonID
        params.fields = [.overview, .primaryImageAspectRatio]
        params.sortBy = [.indexNumber]
        params.sortOrder = [.ascending]
        let request = Paths.getItems(parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func getContinueWatching() async throws -> [BaseItemDto] {
        var params = Paths.GetResumeItemsParameters()
        params.userID = userID
        params.limit = 12
        params.fields = [.primaryImageAspectRatio, .mediaSourceCount]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .thumb]
        params.mediaTypes = [.video]
        let request = Paths.getResumeItems(parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func getNextUp() async throws -> [BaseItemDto] {
        var params = Paths.GetNextUpParameters()
        params.userID = userID
        params.limit = 12
        params.fields = [.primaryImageAspectRatio]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .thumb]
        let request = Paths.getNextUp(parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func search(query: String, scope: SearchScope) async throws -> [BaseItemDto] {
        var params = Paths.GetItemsParameters()
        params.userID = userID
        params.searchTerm = query
        params.isRecursive = true
        params.limit = 50
        params.includeItemTypes = scope.includeItemTypes
        params.fields = [.primaryImageAspectRatio]
        let request = Paths.getItems(parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }
}

// MARK: - Wire-format translation

// Domain → SDK. File-private so SDK types don't leak beyond this file.

private extension ItemSort {
    var wireFormat: ItemSortBy {
        switch field {
        case .title: return .sortName
        case .dateAdded: return .dateCreated
        case .releaseDate: return .premiereDate
        case .communityRating: return .communityRating
        case .officialRating: return .officialRating
        case .runtime: return .runtime
        case .playCount: return .playCount
        case .random: return .random
        }
    }
}

private extension ItemSort.Direction {
    var wireFormat: JellyfinAPI.SortOrder {
        switch self {
        case .ascending: return .ascending
        case .descending: return .descending
        }
    }
}

// Note: both our domain and JellyfinAPI define `ItemFilter`. Inside this
// file-private extension we use the fully qualified names to avoid ambiguity.
private extension ParallaxJellyfin.ItemFilter {
    var wireFormat: [JellyfinAPI.ItemFilter] {
        var out: [JellyfinAPI.ItemFilter] = []
        switch watchState {
        case .all: break
        case .played: out.append(.isPlayed)
        case .unplayed: out.append(.isUnplayed)
        }
        if favoritesOnly { out.append(.isFavorite) }
        return out
    }
}

private extension SearchScope {
    var includeItemTypes: [BaseItemKind] {
        switch self {
        case .all: return [.movie, .series, .episode]
        case .movies: return [.movie]
        case .series: return [.series]
        case .episodes: return [.episode]
        }
    }
}

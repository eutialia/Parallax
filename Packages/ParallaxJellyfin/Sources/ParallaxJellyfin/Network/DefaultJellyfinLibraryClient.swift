import Foundation
import JellyfinAPI
import ParallaxCore

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
        // NOTE: .mediaStreams is requested here to populate poster quality badges (4K / HDR /
        // Dolby Vision). It is the heaviest field on this list query — each item returns audio,
        // subtitle, and video streams. Keep this the only list call that requests it; detail/
        // continue-watching/next-up queries do not need badges.
        params.fields = [.primaryImageAspectRatio, .mediaSourceCount, .mediaStreams]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .logo, .thumb]
        params.filters = filter.wireFormat
        params.genres = filter.genres.isEmpty ? nil : filter.genres
        // `favoritesOnly` is already emitted via filter.wireFormat as
        // .isFavorite — don't double-write here, or a future filter case
        // (e.g. "hide favorites") would fight a hard-coded true.
        params.includeItemTypes = [.movie, .series]

        let request = Paths.getItems(parameters: params)
        let response = try await client().send(request)
        return (response.value.items ?? [], response.value.totalRecordCount ?? 0)
    }

    public func getItemsByIDs(_ ids: [String]) async throws -> [BaseItemDto] {
        guard !ids.isEmpty else { return [] }
        var params = Paths.GetItemsParameters()
        params.userID = userID
        params.ids = ids
        params.fields = [.overview, .primaryImageAspectRatio, .dateCreated]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .logo, .thumb]
        let request = Paths.getItems(parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func getItemDetail(itemID: String) async throws -> BaseItemDto {
        // `Paths.getItem` takes no `fields` parameter, so chapters (and other
        // optional fields like taglines/studios/people) may be absent. Switch to
        // `Paths.getItems` with an explicit field list so chapters are always
        // returned when the server has them.
        var params = Paths.GetItemsParameters()
        params.userID = userID
        params.ids = [itemID]
        params.fields = [.overview, .genres, .taglines, .studios, .people, .chapters]
        let request = Paths.getItems(parameters: params)
        let response = try await client().send(request)
        guard let dto = response.value.items?.first else {
            throw AppError.unexpected("getItemDetail: no item returned for id \(itemID)", underlying: nil)
        }
        return dto
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
        // includeItemTypes=[.episode] keeps trailers, extras, and theme
        // videos out of the list — a season folder can contain non-episode
        // children that we don't want to surface here.
        var params = Paths.GetItemsParameters()
        params.userID = userID
        params.parentID = seasonID
        params.includeItemTypes = [.episode]
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

    public func getRecentlyAdded(limit: Int, includeItemTypes: [BaseItemKind]) async throws -> [BaseItemDto] {
        var params = Paths.GetLatestMediaParameters()
        params.userID = userID
        params.limit = limit
        params.includeItemTypes = includeItemTypes
        params.fields = [.overview, .primaryImageAspectRatio, .dateCreated]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .logo, .thumb]
        params.enableUserData = true
        params.isGroupItems = false
        let request = Paths.getLatestMedia(parameters: params)
        let response = try await client().send(request)
        return response.value
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

    public func setFavorite(itemID: String, isFavorite: Bool) async throws -> UserItemData {
        let request = isFavorite
            ? Paths.markFavoriteItem(itemID: itemID, userID: userID)
            : Paths.unmarkFavoriteItem(itemID: itemID, userID: userID)
        let response = try await client().send(request)
        return response.value.toUserItemData()
    }

    public func setPlayed(itemID: String, isPlayed: Bool) async throws {
        let request = isPlayed
            ? Paths.markPlayedItem(itemID: itemID, userID: userID)
            : Paths.markUnplayedItem(itemID: itemID, userID: userID)
        _ = try await client().send(request)
    }

    public func seriesNextUp(seriesID: String) async throws -> BaseItemDto? {
        var params = Paths.GetNextUpParameters()
        params.userID = userID
        params.seriesID = seriesID
        params.limit = 1
        params.fields = [.overview, .primaryImageAspectRatio]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .thumb]
        let request = Paths.getNextUp(parameters: params)
        let response = try await client().send(request)
        return response.value.items?.first
    }

    public func genres(parentID: String) async throws -> [String] {
        var params = Paths.GetGenresParameters()
        params.parentID = parentID
        params.userID = userID
        let request = Paths.getGenres(parameters: params)
        let response = try await client().send(request)
        return response.value.items?.compactMap(\.name) ?? []
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

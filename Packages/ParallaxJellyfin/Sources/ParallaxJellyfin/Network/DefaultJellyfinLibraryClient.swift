import Foundation
import JellyfinAPI
import ParallaxCore

public final class DefaultJellyfinLibraryClient: JellyfinLibraryClient, Sendable {
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
        scope: LibraryScope,
        filter: ItemFilter,
        sort: ItemSort,
        startIndex: Int,
        limit: Int
    ) async throws -> (items: [BaseItemDto], total: Int) {
        var params = Paths.GetItemsParameters()
        params.userID = userID
        params.startIndex = startIndex
        params.limit = limit
        params.isRecursive = true
        params.sortBy = [sort.wireFormat]
        params.sortOrder = [sort.direction.wireFormat]
        params.fields = [.primaryImageAspectRatio, .mediaSourceCount]
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .logo, .thumb]
        params.genres = filter.genres.isEmpty ? nil : filter.genres
        params.includeItemTypes = [.movie, .series]
        switch scope {
        case .collection(let id):
            params.parentID = id.rawValue
        case .favorites:
            // No parent: favorites span every library, recursive from the root.
            params.filters = [.isFavorite]
        }

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
        guard var dto = response.value.items?.first else {
            throw AppError.unexpected("getItemDetail: no item returned for id \(itemID)", underlying: nil)
        }
        // Quality badges and subtitle detection need media streams; series folders
        // don't carry a single video stream, so skip the heavy field for them.
        if dto.type == .movie {
            var streamParams = Paths.GetItemsParameters()
            streamParams.userID = userID
            streamParams.ids = [itemID]
            streamParams.fields = [.mediaStreams]
            let streamResponse = try await client().send(Paths.getItems(parameters: streamParams))
            dto.mediaStreams = streamResponse.value.items?.first?.mediaStreams
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

    public func mediaSegments(itemID: String) async throws -> [MediaSegmentDto] {
        // Only the kinds the player acts on (Skip Intro/Recap, Next Episode); the
        // server filters the rest out so we don't pay for preview/commercial.
        let request = Paths.getItemSegments(itemID: itemID, includeSegmentTypes: [.intro, .recap, .outro])
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func adjacentEpisodes(seriesID: String, episodeID: String) async throws -> [BaseItemDto] {
        // No seasonID on purpose: the adjacency window must span the whole series
        // so it crosses a season boundary (S1 finale → S2 premiere). The server
        // orders by AiredEpisodeOrder and returns up to [previous, self, next].
        var params = Paths.GetEpisodesParameters()
        params.userID = userID
        params.adjacentTo = episodeID
        params.fields = [.overview, .primaryImageAspectRatio]
        params.enableUserData = true
        params.imageTypeLimit = 1
        params.enableImageTypes = [.primary, .backdrop, .thumb]
        let request = Paths.getEpisodes(seriesID: seriesID, parameters: params)
        let response = try await client().send(request)
        return response.value.items ?? []
    }

    public func genres(scope: LibraryScope) async throws -> [String] {
        var params = Paths.GetGenresParameters()
        params.userID = userID
        switch scope {
        case .collection(let id): params.parentID = id.rawValue
        case .favorites: params.isFavorite = true
        }
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

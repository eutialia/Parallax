import Foundation
import JellyfinAPI
import ParallaxCore

public actor LibraryRepository {
    public static let pageSize: Int = 50

    private let session: Session
    private let client: JellyfinLibraryClient

    public init(session: Session, client: JellyfinLibraryClient) {
        self.session = session
        self.client = client
    }

    public func collections() async throws -> [MediaCollection] {
        do {
            let dtos = try await client.getCollections()
            return dtos.compactMap { $0.toMediaCollection() }
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func items(
        in scope: LibraryScope,
        filter: ParallaxCore.ItemFilter,
        sort: ItemSort,
        cursor: PageCursor?
    ) async throws -> Page<Item> {
        let startIndex = cursor?.startIndex ?? 0
        let response: (items: [BaseItemDto], total: Int)
        do {
            response = try await client.getItems(
                scope: scope,
                filter: filter,
                sort: sort,
                startIndex: startIndex,
                limit: Self.pageSize
            )
        } catch {
            throw ErrorMapping.appError(from: error)
        }

        let items: [Item] = response.items.compactMap(Self.dtoToItem)

        // An empty page mid-pagination (server deletions, or a `total` that
        // over-reports the live count) leaves `consumed == startIndex`, so a
        // `.startIndex(consumed)` cursor would equal the current one and the
        // caller would re-fetch the same empty page forever. Treat any empty
        // page as the end of the sequence.
        let consumed = startIndex + response.items.count
        let nextCursor: PageCursor? = (!response.items.isEmpty && consumed < response.total) ? .startIndex(consumed) : nil
        return Page(items: items, total: response.total, nextCursor: nextCursor)
    }

    public func detail(for itemID: ItemID) async throws -> ItemDetail {
        let dto: BaseItemDto
        do {
            dto = try await client.getItemDetail(itemID: itemID.rawValue)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
        guard let detail = dto.toItemDetail() else {
            throw AppError.unexpected("Library detail missing required fields for item \(itemID.rawValue)", underlying: nil)
        }
        return detail
    }

    public func seasons(of seriesID: ItemID) async throws -> [Season] {
        do {
            let dtos = try await client.getSeasons(seriesID: seriesID.rawValue)
            return dtos.compactMap { $0.toSeason() }
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func episodes(of seasonID: ItemID) async throws -> [Episode] {
        do {
            let dtos = try await client.getEpisodes(seasonID: seasonID.rawValue)
            return dtos.compactMap { $0.toEpisode() }
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func continueWatching() async throws -> [Item] {
        do {
            let dtos = try await client.getContinueWatching()
            let items = dtos.compactMap(Self.dtoToItem)
            return try await enrichHomeShelfItems(items)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func nextUp() async throws -> [Item] {
        do {
            let dtos = try await client.getNextUp()
            let items = dtos.compactMap(Self.dtoToItem)
            return try await enrichHomeShelfItems(items)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func homeHeroFeed(limit: Int = 12) async throws -> [HomeHeroFeedEntry] {
        do {
            let episodeLimit = HomeHeroFeedBuilder.episodeLatestFetchLimit(presentationLimit: limit)
            async let movieDtos = client.getRecentlyAdded(limit: limit, includeItemTypes: [.movie])
            async let episodeDtos = client.getRecentlyAdded(limit: episodeLimit, includeItemTypes: [.episode])
            async let cwDtosTask = client.getContinueWatching()
            let (movies, episodes, cwDtos) = try await (movieDtos, episodeDtos, cwDtosTask)
            let continueWatching = cwDtos.compactMap(Self.dtoToItem)
            let items = (movies + episodes).compactMap(Self.dtoToItem)

            var episodesBySeriesID: [String: [Episode]] = [:]
            for item in items {
                guard case .episode(let episode) = item else { continue }
                episodesBySeriesID[episode.seriesID.rawValue, default: []].append(episode)
            }
            let seriesIDs = Set(episodesBySeriesID.keys)

            var seriesByID: [String: Series] = [:]
            if !seriesIDs.isEmpty {
                let seriesDtos = try await client.getItemsByIDs(Array(seriesIDs))
                for dto in seriesDtos {
                    if let series = dto.toSeries() {
                        seriesByID[series.id.rawValue] = series
                    }
                }
            }

            var firstEpisodeBySeriesID: [String: Episode] = [:]
            for seriesID in seriesIDs.sorted() {
                guard let episodesInBatch = episodesBySeriesID[seriesID], !episodesInBatch.isEmpty else {
                    continue
                }
                let hasS1E1 = episodesInBatch.contains {
                    ($0.parentIndexNumber ?? -1) == 1 && ($0.indexNumber ?? -1) == 1
                }
                if hasS1E1 { continue }

                guard let series = seriesByID[seriesID],
                      HomeHeroFeedBuilder.isNewlyAdded(
                          seriesDate: series.dateAdded,
                          episodes: episodesInBatch
                      ) else { continue }

                if let dto = try await client.seriesNextUp(seriesID: seriesID),
                   let episode = dto.toEpisode() {
                    firstEpisodeBySeriesID[seriesID] = episode
                }
            }

            return HomeHeroFeedBuilder.build(
                latestItems: items,
                seriesByID: seriesByID,
                firstEpisodeBySeriesID: firstEpisodeBySeriesID,
                limit: limit,
                continueWatching: continueWatching
            )
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func setFavorite(itemID: ItemID, isFavorite: Bool) async throws -> UserItemData {
        do {
            return try await client.setFavorite(itemID: itemID.rawValue, isFavorite: isFavorite)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func setPlayed(itemID: ItemID, isPlayed: Bool) async throws {
        do {
            try await client.setPlayed(itemID: itemID.rawValue, isPlayed: isPlayed)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func resumeEpisode(forSeries id: ItemID) async throws -> Episode? {
        let dto: BaseItemDto?
        do {
            dto = try await client.seriesNextUp(seriesID: id.rawValue)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
        return dto?.toEpisode()
    }

    /// Intro/outro markers for an item (native `GET /MediaSegments/{itemId}`).
    /// Empty is the normal no-provider case — callers treat it as "no skip UI".
    public func mediaSegments(for itemID: ItemID) async throws -> [MediaSegment] {
        do {
            let dtos = try await client.mediaSegments(itemID: itemID.rawValue)
            return dtos.compactMap { $0.toMediaSegment() }
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    /// Previous/next episode around `episodeID`, series-wide, from the server's
    /// `adjacentTo` window — the neighbor source for the player's next/previous
    /// buttons and end-of-episode autoplay.
    public func adjacentEpisodes(seriesID: ItemID, episodeID: ItemID) async throws -> AdjacentEpisodes {
        let dtos: [BaseItemDto]
        do {
            dtos = try await client.adjacentEpisodes(seriesID: seriesID.rawValue, episodeID: episodeID.rawValue)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
        return AdjacentEpisodes(around: episodeID, in: dtos.compactMap { $0.toEpisode() })
    }

    public func genres(in scope: LibraryScope) async throws -> [String] {
        do {
            return try await client.genres(scope: scope)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        do {
            switch scope {
            case .all:
                // Fan out per type so a flood of episode matches can't crowd
                // a matching series out of a single shared result limit.
                async let movieDtos = client.search(query: trimmed, scope: .movies)
                async let seriesDtos = client.search(query: trimmed, scope: .series)
                async let episodeDtos = client.search(query: trimmed, scope: .episodes)
                let (m, s, e) = try await (movieDtos, seriesDtos, episodeDtos)
                return SearchResults(
                    movies: m.compactMap { $0.toMovie() },
                    series: s.compactMap { $0.toSeries() },
                    episodes: e.compactMap { $0.toEpisode() }
                )
            case .movies:
                let dtos = try await client.search(query: trimmed, scope: .movies)
                return SearchResults(movies: dtos.compactMap { $0.toMovie() }, series: [], episodes: [])
            case .series:
                let dtos = try await client.search(query: trimmed, scope: .series)
                return SearchResults(movies: [], series: dtos.compactMap { $0.toSeries() }, episodes: [])
            case .episodes:
                let dtos = try await client.search(query: trimmed, scope: .episodes)
                return SearchResults(movies: [], series: [], episodes: dtos.compactMap { $0.toEpisode() })
            }
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    private static func dtoToItem(_ dto: BaseItemDto) -> Item? {
        switch dto.type {
        case .movie: return dto.toMovie().map(Item.movie)
        case .series: return dto.toSeries().map(Item.series)
        case .episode: return dto.toEpisode().map(Item.episode)
        default: return nil
        }
    }

    /// Resume/next-up episode DTOs often omit parent image tags. Batch-fetch
    /// missing season folder art, then series posters as fallback.
    private func enrichHomeShelfItems(_ items: [Item]) async throws -> [Item] {
        let seasonIDs = Set(
            items.compactMap { item -> ItemID? in
                guard case .episode(let e) = item, e.seasonImageRef == nil else { return nil }
                return e.seasonID
            }
        )
        let seriesIDs = Set(
            items.compactMap { item -> ItemID? in
                guard case .episode(let e) = item,
                      e.seasonImageRef == nil, e.seriesImageRef == nil else { return nil }
                return e.seriesID
            }
        )
        let fetchIDs = Array(Set(seasonIDs.map(\.rawValue) + seriesIDs.map(\.rawValue)))
        guard !fetchIDs.isEmpty else { return items }

        let dtos = try await client.getItemsByIDs(fetchIDs)
        var artBySeasonID: [ItemID: ImageRef] = [:]
        var artBySeriesID: [ItemID: ImageRef] = [:]
        for dto in dtos {
            if let season = dto.toSeason(), let ref = season.imageRef(.primary) {
                artBySeasonID[season.id] = ref
            } else if let series = dto.toSeries(), let ref = series.imageRef(.primary) {
                artBySeriesID[series.id] = ref
            }
        }

        return items.map { item in
            guard case .episode(let e) = item, e.seasonImageRef == nil else { return item }
            // Season folder art wins; series poster is the fallback when the
            // season has no primary and the episode carries no series hint.
            if let ref = artBySeasonID[e.seasonID] {
                return item.withSeasonImageRef(ref)
            }
            if e.seriesImageRef == nil, let ref = artBySeriesID[e.seriesID] {
                return item.withSeriesImageRef(ref)
            }
            return item
        }
    }
}

// The browse-surface methods (collections / items / genres) already match
// MediaRepository's requirements verbatim — conformance is declaration-only.
extension LibraryRepository: MediaRepository {}

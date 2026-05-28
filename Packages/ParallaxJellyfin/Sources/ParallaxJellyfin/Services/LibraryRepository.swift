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
        in collection: CollectionID,
        filter: ItemFilter,
        sort: ItemSort,
        cursor: PageCursor?
    ) async throws -> Page<Item> {
        let startIndex = cursor?.startIndex ?? 0
        let response: (items: [BaseItemDto], total: Int)
        do {
            response = try await client.getItems(
                parentID: collection.rawValue,
                filter: filter,
                sort: sort,
                startIndex: startIndex,
                limit: Self.pageSize
            )
        } catch {
            throw ErrorMapping.appError(from: error)
        }

        let items: [Item] = response.items.compactMap(Self.dtoToItem)

        let consumed = startIndex + response.items.count
        let nextCursor: PageCursor? = (consumed < response.total) ? .startIndex(consumed) : nil
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
            return dtos.compactMap(Self.dtoToItem)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func nextUp() async throws -> [Item] {
        do {
            let dtos = try await client.getNextUp()
            return dtos.compactMap(Self.dtoToItem)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
    }

    public func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let dtos: [BaseItemDto]
        do {
            dtos = try await client.search(query: trimmed, scope: scope)
        } catch {
            throw ErrorMapping.appError(from: error)
        }
        var movies: [Movie] = []
        var series: [Series] = []
        var episodes: [Episode] = []
        for dto in dtos {
            switch dto.type {
            case .movie: if let m = dto.toMovie() { movies.append(m) }
            case .series: if let s = dto.toSeries() { series.append(s) }
            case .episode: if let e = dto.toEpisode() { episodes.append(e) }
            default: continue
            }
        }
        return SearchResults(movies: movies, series: series, episodes: episodes)
    }

    private static func dtoToItem(_ dto: BaseItemDto) -> Item? {
        switch dto.type {
        case .movie: return dto.toMovie().map(Item.movie)
        case .series: return dto.toSeries().map(Item.series)
        case .episode: return dto.toEpisode().map(Item.episode)
        default: return nil
        }
    }
}

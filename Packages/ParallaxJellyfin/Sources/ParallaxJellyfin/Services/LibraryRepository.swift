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

        let items: [Item] = response.items.compactMap { dto in
            switch dto.type {
            case .movie: return dto.toMovie().map(Item.movie)
            case .series: return dto.toSeries().map(Item.series)
            case .episode: return dto.toEpisode().map(Item.episode)
            default: return nil
            }
        }

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
}

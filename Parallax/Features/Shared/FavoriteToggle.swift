import Foundation
import ParallaxCore
import ParallaxJellyfin

/// Shared Jellyfin favorite persistence for every surface (Home hero, movie/series detail).
/// One in-flight guard per `ItemID` so rapid taps or duplicate buttons don't issue parallel
/// `POST`/`DELETE /UserFavoriteItems/{id}` calls.
@MainActor
enum FavoriteToggle {
    enum Outcome: Sendable {
        case success(UserItemData)
        case skipped
        case failure(AppError)
    }

    private static var inFlight = Set<ItemID>()

    static func perform(
        itemID: ItemID,
        currentlyFavorite: Bool,
        via repo: LibraryRepository
    ) async -> Outcome {
        guard inFlight.insert(itemID).inserted else { return .skipped }
        defer { inFlight.remove(itemID) }

        do {
            let userData = try await repo.setFavorite(itemID: itemID, isFavorite: !currentlyFavorite)
            return .success(userData)
        } catch let error as AppError {
            return .failure(error)
        } catch {
            return .failure(.unexpected("Favorite toggle failed.", underlying: AnySendableError(error)))
        }
    }
}
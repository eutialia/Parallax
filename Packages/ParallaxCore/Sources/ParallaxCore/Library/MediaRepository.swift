import Foundation

/// The source-agnostic browse surface. Jellyfin's `LibraryRepository` and the
/// Phase-2 `SMBMediaRepository` both conform; the library list/grid view models
/// depend on `any MediaRepository`, so a non-Jellyfin source drives the same UI.
///
/// Deliberately narrow: this is *only* the browse surface. Jellyfin-specific
/// reads (home feed, detail, search, favorites, episode succession) stay on the
/// concrete `LibraryRepository` and are consumed only by Jellyfin screens.
public protocol MediaRepository: Sendable {
    func collections() async throws -> [MediaCollection]
    func items(in scope: LibraryScope, filter: ItemFilter, sort: ItemSort, cursor: PageCursor?) async throws -> Page<Item>
    func genres(in scope: LibraryScope) async throws -> [String]
}

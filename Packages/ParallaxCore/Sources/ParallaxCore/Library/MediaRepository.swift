import Foundation

/// The source-agnostic browse surface. Jellyfin's `LibraryRepository` conforms;
/// the library list/grid view models depend on `any MediaRepository` so the same
/// UI can be driven by any conforming source. (SMB browses shares directly via
/// `SMBFileSource` rather than through this protocol — it carries no collections.)
///
/// Deliberately narrow: this is *only* the browse surface. Jellyfin-specific
/// reads (home feed, detail, search, favorites, episode succession) stay on the
/// concrete `LibraryRepository` and are consumed only by Jellyfin screens.
public protocol MediaRepository: Sendable {
    func collections() async throws -> [MediaCollection]
    func items(in scope: LibraryScope, filter: ItemFilter, sort: ItemSort, cursor: PageCursor?) async throws -> Page<Item>
    func genres(in scope: LibraryScope) async throws -> [String]
    /// Releases any live connection a conformer holds. HTTP-backed repositories (Jellyfin)
    /// are stateless, so the default is a no-op.
    func teardown() async
}

public extension MediaRepository {
    func teardown() async {}
}

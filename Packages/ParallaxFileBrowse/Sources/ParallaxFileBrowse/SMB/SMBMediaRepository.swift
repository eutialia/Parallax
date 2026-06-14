import Foundation
import ParallaxCore

/// A `MediaRepository` that surfaces flat media files from SMB share roots.
///
/// Each configured root becomes one `MediaCollection`. Items within a collection
/// are the top-level media files under that root, filtered by `SMBFileSource`
/// (no recursion, no series/season hierarchy). Source identity is tagged by the
/// app at the `LibraryEntry` boundary — this type is source-neutral.
///
/// `SMBMediaRepository` is a `struct` (not an actor) because it holds only
/// immutable state: the lister is already `Sendable`, and all mutation lives in
/// the `SMBLister` implementation itself. Matching the `LibraryRepository`
/// pattern which is an `actor` would add needless serialisation overhead here
/// since there's no mutable per-instance state to protect.
public struct SMBMediaRepository: MediaRepository {

    private let lister: any SMBLister
    private let share: String
    private let roots: [String]

    public init(lister: any SMBLister, share: String, roots: [String]) {
        self.lister = lister
        self.share = share
        self.roots = roots
    }

    // MARK: - MediaRepository

    public func collections() async throws -> [MediaCollection] {
        roots.map { root in
            MediaCollection(
                id: collectionID(for: root),
                name: displayName(for: root),
                collectionType: .movies,
                primaryTag: nil
            )
        }
    }

    public func items(
        in scope: LibraryScope,
        filter: ItemFilter,
        sort: ItemSort,
        cursor: PageCursor?
    ) async throws -> Page<Item> {
        guard case .collection(let collectionID) = scope,
              let root = root(from: collectionID) else {
            return Page(items: [], total: 0, nextCursor: nil)
        }

        let source = SMBFileSource(lister: lister, share: share, root: root)
        let entries = try await source.mediaFiles(in: "")
        let items: [Item] = entries.map { entry in
            item(from: entry, share: share, root: root)
        }
        return Page(items: items, total: items.count, nextCursor: nil)
    }

    public func genres(in scope: LibraryScope) async throws -> [String] {
        []
    }

    // MARK: - ID derivation

    /// Stable `CollectionID` encoding both share and root so the app can round-trip it.
    /// Format: `"<share>:<root>"` — colons are not valid in SMB share names.
    private func collectionID(for root: String) -> CollectionID {
        CollectionID(rawValue: "\(share):\(root)")
    }

    /// Decodes a root path back from a `CollectionID` minted by `collectionID(for:)`.
    /// Returns `nil` if the ID wasn't produced by this share (unknown ID).
    private func root(from id: CollectionID) -> String? {
        let prefix = "\(share):"
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        let root = String(id.rawValue.dropFirst(prefix.count))
        // Confirm the root is one we actually manage (guard against spoofed IDs).
        guard roots.contains(root) else { return nil }
        return root
    }

    // MARK: - Display name

    private func displayName(for root: String) -> String {
        let lastComponent = (root as NSString).lastPathComponent
        return lastComponent.isEmpty ? share : lastComponent
    }

    // MARK: - Entry → Item mapping

    private func item(from entry: SMBDirectoryEntry, share: String, root: String) -> Item {
        // ItemID encodes the full SMB path so two files at different roots with
        // the same name don't collide, and the ID is stable across sessions.
        let path = root.isEmpty ? entry.name : "\(root)/\(entry.name)"
        let itemID = ItemID(rawValue: "\(share):\(path)")

        let title = (entry.name as NSString).deletingPathExtension

        let movie = Movie(
            id: itemID,
            title: title,
            overview: nil,
            year: nil,
            runtime: nil,
            communityRating: nil,
            officialRating: nil,
            genres: [],
            primaryTag: nil,
            backdropTags: [],
            logoTag: nil,
            thumbTag: nil,
            dateAdded: entry.modifiedAt,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false),
            width: nil,
            height: nil,
            videoRangeType: nil,
            hasSubtitles: false
        )
        return .movie(movie)
    }
}

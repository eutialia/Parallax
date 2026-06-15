import Foundation
import OSLog
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

    private static let logger = Logger(subsystem: "Parallax", category: "SMBMediaRepository")

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
        let entries: [SMBDirectoryEntry]
        do {
            entries = try await source.mediaFiles(in: "")
        } catch {
            // Map the raw libsmb2/AMSMB2 error to a typed AppError so the grid shows a
            // meaningful message (and logs the real cause) instead of letting a bare NSError
            // fall through to LibraryGridViewModel's generic "Something went wrong."
            throw Self.mapListError(error, share: share, root: root)
        }
        let items: [Item] = entries.map { entry in
            item(from: entry, share: share, root: root)
        }
        return Page(items: items, total: items.count, nextCursor: nil)
    }

    public func genres(in scope: LibraryScope) async throws -> [String] {
        []
    }

    /// Closes the live SMB share connection the lister opened on first `items()`. Called
    /// when the browsing surface is torn down (the grid view model's deinit) so a visit
    /// doesn't leave a connection open on the NAS until ARC eventually reclaims the lister.
    public func teardown() async {
        await lister.disconnect()
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

    // MARK: - Public ID decoding (reverse of item(from:share:root:))

    /// The share-relative path encoded into an `ItemID` minted by this repository, or
    /// nil if `itemID` wasn't produced for `share`. Inverse of `item(from:share:root:)`.
    ///
    /// Example: for share `"Media"` and ItemID `"Media:Movies/Film.mkv"` this returns
    /// `"Movies/Film.mkv"`. A foreign ItemID (wrong prefix) returns nil.
    public static func playablePath(fromItemID itemID: ItemID, share: String) -> String? {
        let prefix = "\(share):"
        guard itemID.rawValue.hasPrefix(prefix) else { return nil }
        return String(itemID.rawValue.dropFirst(prefix.count))
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

    // MARK: - Error mapping

    /// Maps a raw libsmb2/AMSMB2 enumeration failure to a typed `AppError`, logging the
    /// underlying `NSError` (domain/code/message) so the cause is diagnosable — a bare
    /// NSError otherwise surfaced as "Something went wrong." with nothing in the log.
    /// Credentials never appear here: the error carries none, and only the share/root are
    /// logged, never the lister's `URLCredential`.
    private static func mapListError(_ error: Error, share: String, root: String) -> AppError {
        let ns = error as NSError
        logger.error("SMB list failed [share=\(share, privacy: .public) root=\(root, privacy: .public)]: \(ns.domain, privacy: .public)#\(ns.code) — \(ns.localizedDescription, privacy: .public)")
        // libsmb2/AMSMB2 surface POSIX errnos either as a bridged POSIXError or as a raw
        // NSError in NSPOSIXErrorDomain — accept both. A non-POSIX error (custom domain) maps
        // to the general "connection lost".
        let posixCode: Int32? = (error as? POSIXError).map { $0.code.rawValue }
            ?? (ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : nil)
        switch posixCode {
        case POSIXErrorCode.EACCES.rawValue, POSIXErrorCode.EPERM.rawValue:
            return .source(.permissionDenied)
        case POSIXErrorCode.ENOENT.rawValue, POSIXErrorCode.ENOTDIR.rawValue, POSIXErrorCode.ENODEV.rawValue:
            return .source(.notFound)
        default:
            return .source(.connectionLost)
        }
    }
}

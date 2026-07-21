import Foundation
import OSLog
import ParallaxCore

/// Top-level media file accessor for a single SMB share + root path.
/// Lists one directory level only (no recursion), filters to known media extensions.
/// Credentials are never embedded in URLs — callers supply them via transport options.
public struct SMBFileSource: Sendable {

    private static let logger = Log.custom(category: "SMBFileSource")

    // Extensions recognised as playable media — a libVLC-decodable ALLOWLIST (not a blocklist),
    // so non-media siblings and temp-suffix partials (.part/.crdownload/.!qB/.aria2) never reach
    // the grid. Widened past the Phase 2 spec §3a core to the legacy/less-common containers libVLC
    // still decodes (RealMedia via RV40+Cook, Ogg/Theora, DVD VOB, AVCHD .mts, ASF, MPEG-2 ES).
    static let mediaExtensions: Set<String> = [
        "mkv", "webm",
        "mp4", "m4v", "mov", "3gp",
        "ts", "m2ts", "mts",
        "mpg", "mpeg", "m2v", "vob",
        "avi", "divx",
        "wmv", "asf",
        "flv",
        "rmvb", "rm",
        "ogv", "ogm",
    ]

    private let lister: any SMBLister
    private let host: String
    private let share: String
    private let root: String

    public init(lister: any SMBLister, host: String = "", share: String, root: String) {
        self.lister = lister
        self.host = host
        self.share = share
        self.root = root
    }

    /// Raw directory listing. Lists `path`; when `path` is empty, lists the configured `root`.
    /// A non-empty `path` replaces `root` (it is not joined to it). No filtering.
    /// Package-internal so `SMBSubtitleResolver` reuses this same root/path resolution.
    func allEntries(in path: String) async throws -> [SMBDirectoryEntry] {
        let listPath = path.isEmpty ? root : path
        return try await lister.list(share: share, path: listPath)
    }

    /// True for a non-directory entry whose extension is a recognised playable media type.
    /// Deliberately size-AGNOSTIC: the zero-byte exclusion is a grid/playability concern applied
    /// in `mediaFiles`, not here. The subtitle resolver's lonely-video count reuses this predicate,
    /// and counting a zero-byte stub as a present video is the SAFE behaviour there — it keeps the
    /// loose cross-attach fallback OFF (a stub beside one real video reads as two videos, not one),
    /// rather than letting a grid concern silently flip subtitle matching. Shared so the count and
    /// `mediaFiles` agree on "is this a media-typed file".
    static func isMediaFile(_ entry: SMBDirectoryEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        return mediaExtensions.contains((entry.name as NSString).pathExtension.lowercased())
    }

    // MARK: - ItemID codec (public statics, shared by browse path + playback resolver)

    /// Encodes share + share-relative path into a stable `ItemID`.
    /// Format: `"<share>:<path>"` — colons are not valid in SMB share names.
    public static func itemID(share: String, path: String) -> ItemID {
        ItemID(rawValue: "\(share):\(path)")
    }

    /// Decodes an `ItemID` produced by `itemID(share:path:)`.
    /// Splits on the FIRST colon only — share names never contain colons.
    /// Returns `nil` if the value has no colon (foreign / malformed ID), if the share portion is
    /// empty (e.g. `":Movies/Film.mkv"` — no share to anchor a URL on), or if the path portion is
    /// empty (e.g. `"Media:"`) — none of these is playable.
    public static func decodeItemID(_ id: ItemID) -> (share: String, path: String)? {
        guard let colon = id.rawValue.firstIndex(of: ":") else { return nil }
        let share = String(id.rawValue[..<colon])
        let path = String(id.rawValue[id.rawValue.index(after: colon)...])
        guard !share.isEmpty, !path.isEmpty else { return nil }
        return (share, path)
    }

    // MARK: - Entry → Item mapping

    /// Maps a single `SMBDirectoryEntry` to an `Item`, embedding the full share-relative path in
    /// the `ItemID`. `dirPath` is the directory being listed; when empty the entry is at the root.
    public static func item(from entry: SMBDirectoryEntry, share: String, in dirPath: String) -> Item {
        let path = dirPath.isEmpty ? entry.name : "\(dirPath)/\(entry.name)"
        let title = (entry.name as NSString).deletingPathExtension
        let movie = Movie(
            id: itemID(share: share, path: path),
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
            hasSubtitles: false,
            size: entry.size
        )
        return .movie(movie)
    }

    // MARK: - Error mapping

    /// Maps a raw libsmb2/AMSMB2 enumeration failure to a typed `AppError`, logging the
    /// underlying `NSError` (domain/code/message). Only share/path are logged — never credentials.
    public static func mapListError(_ error: Error, share: String, path: String) -> AppError {
        let ns = error as NSError
        logger.error("SMB list failed [share=\(share, privacy: .public) path=\(path, privacy: .public)]: \(ns.domain, privacy: .public)#\(ns.code) — \(ns.localizedDescription, privacy: .public)")
        return classify(error)
    }

    /// Maps a share-enumeration (`listShares()`) failure to a typed `AppError` — same
    /// classification as `mapListError`, logged per host since no share is in play yet.
    public static func mapShareListError(_ error: Error, host: String) -> AppError {
        let ns = error as NSError
        logger.error("SMB share list failed [host=\(host, privacy: .public)]: \(ns.domain, privacy: .public)#\(ns.code) — \(ns.localizedDescription, privacy: .public)")
        return classify(error)
    }

    /// EPERM is deliberately NOT bucketed with EACCES. libsmb2's only EPERM source is its
    /// NT-status→errno table — the TCP connect succeeded and the SERVER refused the session —
    /// and live-server probing (nas.example.lan, 2026-07-21) showed every credential failure shape
    /// (guest, empty/wrong password, unknown user) surfaces as EPERM, while a genuine share
    /// ACL denial (NT_STATUS_ACCESS_DENIED) arrives as EACCES. So EPERM is a sign-in failure:
    /// the recovery is re-entering credentials, not requesting access to an item.
    private static func classify(_ error: Error) -> AppError {
        let ns = error as NSError
        let posixCode: Int32? = (error as? POSIXError).map { $0.code.rawValue }
            ?? (ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : nil)
        switch posixCode {
        case POSIXErrorCode.EPERM.rawValue:
            return .auth(.invalidCredentials)
        case POSIXErrorCode.EACCES.rawValue:
            return .source(.permissionDenied)
        case POSIXErrorCode.ENOENT.rawValue, POSIXErrorCode.ENOTDIR.rawValue, POSIXErrorCode.ENODEV.rawValue:
            return .source(.notFound)
        default:
            return .source(.connectionLost)
        }
    }

    /// Lists top-level media files in `path` (or the configured `root` when `path` is empty).
    /// Directories and non-media files are excluded. No recursion. Zero-byte stubs (an interrupted
    /// download's freshly-created placeholder — they can't play) are dropped HERE, the grid path
    /// only. (A sparse/truncated file with a full logical size still passes; that residual leaves
    /// no listing-visible trace and is handled downstream by the thumbnail negative cache.)
    public func mediaFiles(in path: String) async throws -> [SMBDirectoryEntry] {
        try await allEntries(in: path).filter { Self.isMediaFile($0) && $0.size > 0 }
    }

    /// Builds an `smb://host/share/path` URL. Credentials are NEVER included in the string.
    /// Path components are percent-encoded (see `SMBURL`) so `#`/`?` in a real filename don't
    /// truncate the URL.
    public func playableURL(for entry: SMBDirectoryEntry, in path: String) -> URL? {
        let listPath = path.isEmpty ? root : path
        let trimmed = listPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filePath = trimmed.isEmpty ? entry.name : "\(trimmed)/\(entry.name)"
        return SMBURL.make(host: host, share: share, path: filePath)
    }

    // MARK: - browse

    /// One directory level at `path` (or the configured root when empty), partitioned into
    /// subfolders and media (mapped to `Item`), each ordered by `sort`. Folders are kept in their
    /// own array so they ALWAYS render above media regardless of `sort`; the sort only orders within
    /// each group. Non-media and zero-byte files are excluded (same rule as `mediaFiles`). No recursion.
    public func browse(in path: String, sort: SMBBrowseSort = .default) async throws -> SMBBrowseListing {
        let dirPath = path.isEmpty ? root : path
        let entries = try await allEntries(in: path)
        let folders = sort.sorted(entries.filter(\.isDirectory))
        let media = sort.sorted(entries.filter { Self.isMediaFile($0) && $0.size > 0 })
            .map { Self.item(from: $0, share: share, in: dirPath) }
        return SMBBrowseListing(folders: folders, media: media)
    }

    /// Forwards disconnect to the underlying lister.
    public func disconnect() async {
        await lister.disconnect()
    }
}

// MARK: - SMBBrowseListing

/// A single directory listing partitioned into subfolders and playable media items.
public struct SMBBrowseListing: Sendable {
    public let folders: [SMBDirectoryEntry]
    public let media: [Item]
    public init(folders: [SMBDirectoryEntry], media: [Item]) {
        self.folders = folders
        self.media = media
    }
}

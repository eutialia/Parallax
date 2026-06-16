import Foundation

/// Top-level media file accessor for a single SMB share + root path.
/// Lists one directory level only (no recursion), filters to known media extensions.
/// Credentials are never embedded in URLs — callers supply them via transport options.
public struct SMBFileSource: Sendable {

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

    /// Forwards disconnect to the underlying lister.
    public func disconnect() async {
        await lister.disconnect()
    }
}

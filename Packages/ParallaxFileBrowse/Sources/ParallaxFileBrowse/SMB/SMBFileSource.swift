import Foundation

/// Top-level media file accessor for a single SMB share + root path.
/// Lists one directory level only (no recursion), filters to known media extensions.
/// Credentials are never embedded in URLs — callers supply them via transport options.
public struct SMBFileSource: Sendable {

    // Extensions recognised as playable media, per Phase 2 spec §3a.
    static let mediaExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts",
        "webm", "wmv", "flv", "mpg", "mpeg", "m2ts",
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
    /// Shared so the subtitle resolver's video count and `mediaFiles` apply one definition.
    static func isMediaFile(_ entry: SMBDirectoryEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        return mediaExtensions.contains((entry.name as NSString).pathExtension.lowercased())
    }

    /// Lists top-level media files in `path` (or the configured `root` when `path` is empty).
    /// Directories and non-media files are excluded. No recursion.
    public func mediaFiles(in path: String) async throws -> [SMBDirectoryEntry] {
        try await allEntries(in: path).filter(Self.isMediaFile)
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

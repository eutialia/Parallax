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

    /// Lists top-level media files under `path` (relative to the configured root).
    /// Directories and non-media files are excluded. No recursion.
    public func mediaFiles(in path: String) async throws -> [SMBDirectoryEntry] {
        let listPath = path.isEmpty ? root : path
        let entries = try await lister.list(share: share, path: listPath)
        return entries.filter { entry in
            guard !entry.isDirectory else { return false }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            return Self.mediaExtensions.contains(ext)
        }
    }

    /// Builds an `smb://host/share/path` URL. Credentials are NEVER included in the string.
    public func playableURL(for entry: SMBDirectoryEntry, in path: String) -> URL? {
        let listPath = path.isEmpty ? root : path
        let filePath: String
        if listPath.isEmpty {
            filePath = entry.name
        } else {
            let trimmed = listPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            filePath = trimmed.isEmpty ? entry.name : "\(trimmed)/\(entry.name)"
        }
        let raw = "smb://\(host)/\(share)/\(filePath)"
        return URL(string: raw)
    }

    /// Forwards disconnect to the underlying lister.
    public func disconnect() async {
        await lister.disconnect()
    }
}

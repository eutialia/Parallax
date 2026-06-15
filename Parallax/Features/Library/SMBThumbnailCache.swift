import CryptoKit
import Foundation

/// Identity of an SMB file for thumbnail caching.
///
/// Keyed on the owning server's id PLUS the share-relative path, then the file's size and
/// modification date. The server id discriminates two different SMB servers that happen to
/// hold the same share-relative path (e.g. both have `Movies/Film.mkv`), and size+mtime mean
/// a changed file produces a different key — the stale thumbnail is bypassed rather than served.
struct SMBThumbnailKey: Hashable, Sendable {
    let serverID: String  // unique per SMB server (ServerID.rawValue)
    let path: String      // smb path within the share, e.g. "Movies/Film.mkv"
    let size: Int64
    let modifiedAt: Date?
}

/// Disk-backed cache of locally generated SMB thumbnails.
///
/// Returns a `file://` URL for an item's thumbnail, generating and caching it on a miss.
/// Generation is injected as a closure returning PNG `Data`, so the cache is VLC-agnostic
/// and fully unit-testable with a fake generator. The produced URL is meant to feed
/// `ArtworkSource.local(_:)`.
actor SMBThumbnailCache {
    private let directory: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - directory: where thumbnails live; defaults to `<Caches>/SMBThumbnails/`.
    ///   - fileManager: injectable for tests.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directory = caches.appendingPathComponent("SMBThumbnails", isDirectory: true)
        }
    }

    /// The cached thumbnail URL for `key`, generating it on a miss.
    ///
    /// Hit: returns the existing file URL without calling `generate`. Miss: runs `generate`,
    /// writes its PNG bytes atomically, and returns the new URL. Returns `nil` if `generate`
    /// throws or the write fails — no partial file is left behind.
    func thumbnailURL(for key: SMBThumbnailKey, generate: () async throws -> Data) async -> URL? {
        let url = directory.appendingPathComponent(fileName(for: key))

        if fileManager.fileExists(atPath: url.path) {
            return url
        }

        let data: Data
        do {
            data = try await generate()
        } catch {
            return nil
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        // Follow-up: bounded-size eviction; currently grows unbounded in Caches (OS purges under pressure).
        return url
    }

    /// `<sha256(serverID + path)>-<size>-<mtimeEpoch>.png`. Hashing the server id together
    /// with the path keeps two servers' identical relative paths in distinct cache files; the
    /// size + modification-date suffix means a changed file never collides with its own stale
    /// entry. The NUL separator can't appear in a host id or a filename, so the digest input
    /// is unambiguous.
    private func fileName(for key: SMBThumbnailKey) -> String {
        let digest = SHA256.hash(data: Data("\(key.serverID)\u{0}\(key.path)".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let mtime = key.modifiedAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "na"
        return "\(hash)-\(key.size)-\(mtime).png"
    }
}

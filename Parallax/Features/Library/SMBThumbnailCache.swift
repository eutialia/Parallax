import CryptoKit
import Foundation

/// Identity of an SMB file for thumbnail caching.
///
/// Keyed on the share-relative path plus the file's size and modification date so a
/// changed file on the share produces a different key — the stale thumbnail is bypassed
/// rather than served.
struct SMBThumbnailKey: Hashable, Sendable {
    let path: String     // smb path within the share, e.g. "Movies/Film.mkv"
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

    /// `<sha256(path)>-<size>-<mtimeEpoch>.png`. The size and modification-date suffix
    /// guarantees two otherwise-identical paths that differ in size or mtime map to
    /// distinct filenames, so a changed file never collides with its own stale cache entry.
    private func fileName(for key: SMBThumbnailKey) -> String {
        let digest = SHA256.hash(data: Data(key.path.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let mtime = key.modifiedAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "na"
        return "\(hash)-\(key.size)-\(mtime).png"
    }
}

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

/// A cached thumbnail: its on-disk PNG plus the source duration persisted alongside it (a small
/// `.dur` sidecar). `duration` is nil when none was stored — an old entry written before duration
/// extraction, or a file libvlc couldn't read a length from.
struct CachedThumbnail: Sendable, Equatable {
    let url: URL
    let duration: Duration?
}

/// Disk-backed store of locally generated SMB thumbnails — a PURE storage layer (no generation,
/// no concurrency policy; `MediaArtworkProvider` owns those).
///
/// Two operations: `existing(for:)` peeks for a cached file (and stamps its access date so
/// eviction is true-LRU), and `store(_:duration:for:)` writes generated PNG bytes. Splitting peek
/// from store lets the caller distinguish a generation failure (never calls `store`) from a write
/// failure (`store` returns nil) — they must not be conflated, or a write blip would poison a
/// perfectly decodable file. The produced URL is meant to feed `ArtworkSource.local(_:)`.
///
/// Each PNG carries an optional `.dur` sidecar holding the source duration in milliseconds, so a
/// cache hit can show the tile's runtime without re-decoding the video. The sidecar is best-effort:
/// its absence (or a parse failure) just yields a nil duration, never a broken thumbnail.
actor SMBThumbnailCache {
    private let directory: URL
    private let fileManager: FileManager

    /// Total cache-size ceiling. At ~50–200 KB per PNG this holds ~1,500–3,000 thumbnails —
    /// generous for a NAS library. Once exceeded, `sweep()` evicts least-recently-accessed first.
    private let sizeCapBytes: Int64
    /// Post-sweep target — trimming to below the cap (not exactly to it) keeps a sweep from
    /// re-firing on the very next write.
    private let trimTargetBytes: Int64
    /// Sweep cadence: the directory scan is amortised over this many writes rather than run on
    /// every miss. The sha256-size-mtime filename self-invalidates (a changed file is a new
    /// file), so between sweeps the only unbounded growth is orphaned old-version entries.
    private let sweepInterval: Int
    private var writesSinceSweep: Int

    /// - Parameters:
    ///   - directory: where thumbnails live; defaults to `<Caches>/SMBThumbnails/`.
    ///   - fileManager: injectable for tests.
    ///   - sizeCapBytes / trimTargetBytes / sweepInterval: eviction tuning; small values in tests
    ///     exercise the sweep without writing thousands of files.
    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        sizeCapBytes: Int64 = 150 * 1024 * 1024,
        trimTargetBytes: Int64 = 120 * 1024 * 1024,
        sweepInterval: Int = 32
    ) {
        self.fileManager = fileManager
        self.sizeCapBytes = sizeCapBytes
        self.trimTargetBytes = trimTargetBytes
        self.sweepInterval = max(1, sweepInterval)
        // Start "due": the first store of a session sweeps once, bounding a cache that persisted
        // across launches (the counter resets per process; the on-disk directory does not, so a
        // purely write-amortised cadence could blow past the cap after relaunch before catching up).
        self.writesSinceSweep = self.sweepInterval
        if let directory {
            self.directory = directory
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directory = caches.appendingPathComponent("SMBThumbnails", isDirectory: true)
        }
    }

    /// The cached thumbnail for `key` if a file already exists, else nil. Never generates. The
    /// returned record carries the duration read from the PNG's `.dur` sidecar (nil if absent).
    ///
    /// On a hit it stamps the file's access date to now so `sweep()` can evict by TRUE recency:
    /// iOS does not bump a file's access time on a plain `stat`/read, so the cache must set it
    /// explicitly (the same technique Nuke's `DataCache` uses) — otherwise eviction silently
    /// degrades to oldest-written-first regardless of how often a thumbnail is actually viewed.
    func existing(for key: SMBThumbnailKey) -> CachedThumbnail? {
        let url = directory.appendingPathComponent(fileName(for: key))
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        touchAccessDate(url)
        return CachedThumbnail(url: url, duration: readDuration(for: url))
    }

    /// Writes `data` as the thumbnail for `key` (plus `duration` as a `.dur` sidecar when present),
    /// returning the cached record, or nil if the PNG write fails (createDirectory / atomic-write
    /// error). A nil here means a STORAGE failure, NOT a generation failure — the caller already
    /// produced valid bytes — so the caller must not treat it as a reason to negative-cache the
    /// key. No partial file is left behind on failure.
    func store(_ data: Data, duration: Duration?, for key: SMBThumbnailKey) -> CachedThumbnail? {
        let url = directory.appendingPathComponent(fileName(for: key))
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        // Persist the duration sidecar and report back ONLY what actually reached disk: a failed
        // sidecar write (or no duration) means a later `existing(for:)` reads nil, so store() must
        // return nil too — otherwise the same key shows a duration now and none after a
        // scroll-off/scroll-back. Re-storing a key without a duration also clears any stale sidecar.
        let persistedDuration: Duration?
        if let duration, writeDuration(duration, for: url) {
            persistedDuration = duration
        } else {
            removeDuration(for: url)
            persistedDuration = nil
        }

        // Amortise the bounded-LRU sweep across writes — never on the read/hit path, so the steady
        // state (all thumbnails cached) costs nothing.
        writesSinceSweep += 1
        if writesSinceSweep >= sweepInterval {
            writesSinceSweep = 0
            sweep()
        }
        return CachedThumbnail(url: url, duration: persistedDuration)
    }

    /// Allocated size of every cached file (PNGs + `.dur` sidecars), for a "Clear Cache" readout.
    /// 0 when the directory doesn't exist yet (SMB never browsed) or can't be listed.
    func totalSize() -> Int64 {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            return sum + Int64(size)
        }
    }

    /// Wipes the whole cache directory (PNGs + sidecars). `store` recreates it on the next write.
    /// Re-arms the first-write sweep so a freshly-refilled cache is bounded from the next launch.
    func clear() {
        try? fileManager.removeItem(at: directory)
        writesSinceSweep = sweepInterval
    }

    /// The `.dur` sidecar URL for a PNG: same base name, `dur` extension (`<name>.dur`). Holds the
    /// source duration in whole milliseconds as decimal text.
    private func durationSidecarURL(for pngURL: URL) -> URL {
        pngURL.deletingPathExtension().appendingPathExtension("dur")
    }

    /// Reads the duration from `pngURL`'s sidecar, or nil if it's missing/unparseable.
    private func readDuration(for pngURL: URL) -> Duration? {
        guard let data = try? Data(contentsOf: durationSidecarURL(for: pngURL)),
              let text = String(data: data, encoding: .utf8),
              let milliseconds = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              milliseconds > 0
        else { return nil }
        return .milliseconds(milliseconds)
    }

    /// Writes the duration sidecar (whole milliseconds), returning whether it reached disk. A
    /// non-positive duration or a write error yields false, and `store` then reports a nil duration
    /// so its in-memory result can't disagree with a later on-disk `existing(for:)` read.
    private func writeDuration(_ duration: Duration, for pngURL: URL) -> Bool {
        let milliseconds = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else { return false }
        do {
            try Data(String(milliseconds).utf8).write(to: durationSidecarURL(for: pngURL), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes a PNG's `.dur` sidecar if present (best-effort). Pairs with PNG eviction in `sweep`
    /// and clears a stale sidecar when a key is re-stored without a duration.
    private func removeDuration(for pngURL: URL) {
        try? fileManager.removeItem(at: durationSidecarURL(for: pngURL))
    }

    /// Stamps `url`'s access date to now so a hit counts as "recently used" for `sweep()`.
    private func touchAccessDate(_ url: URL) {
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Bounded-LRU eviction. Lists the cache directory once for size + access time; if the total
    /// exceeds `sizeCapBytes`, deletes least-recently-accessed files until under `trimTargetBytes`.
    /// Access time is meaningful because `existing` stamps it on every hit. Best-effort: a
    /// transient list/remove failure just defers eviction to the next sweep.
    private func sweep() {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, accessed: Date)] = []
        var total: Int64 = 0
        for entry in entries {
            // PNGs are the eviction units; `.dur` sidecars are tiny and ride their PNG out (below),
            // so they're neither counted toward the cap nor evicted on their own.
            guard entry.pathExtension == "png" else { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            files.append((entry, size, values.contentAccessDate ?? .distantPast))
            total += size
        }

        guard total > sizeCapBytes else { return }

        // Oldest access first → evict until under the trim target. Each PNG takes its sidecar with it.
        files.sort { $0.accessed < $1.accessed }
        for file in files where total > trimTargetBytes {
            if (try? fileManager.removeItem(at: file.url)) != nil {
                total -= file.size
                removeDuration(for: file.url)
            }
        }
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

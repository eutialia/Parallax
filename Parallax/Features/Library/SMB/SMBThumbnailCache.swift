import Foundation
import ParallaxCore

/// Identity of an SMB file for thumbnail caching.
///
/// Keyed on the owning server's id, the share, and the share-relative path, then the file's size
/// and modification date. Since the move to one server-id per host (`smb-<host>`), a single server
/// hosts many shares, so the SHARE is what keeps two files at the same share-relative path on
/// different shares of one host (both `Movies/Film.mkv`) from colliding; size+mtime mean a changed
/// file produces a different key — the stale thumbnail is bypassed rather than served.
struct SMBThumbnailKey: Hashable, Sendable {
    let serverID: String  // per SMB server — host-level since the migration (ServerID.rawValue == "smb-<host>")
    let share: String     // the share the file lives on; one host serves many, so this discriminates them
    let path: String      // share-relative path, e.g. "Movies/Film.mkv"
    let size: Int64
    let modifiedAt: Date?
}

/// A cached thumbnail: its on-disk image plus the source duration persisted alongside it (a small
/// `.dur` sidecar). `duration` is nil when none was stored — a sidecar-image thumbnail (which has no
/// video length), an old entry written before duration extraction, or a file libvlc couldn't read a
/// length from.
struct CachedThumbnail: Sendable, Equatable {
    let url: URL
    let duration: Duration?
}

/// Disk-backed store of locally generated SMB thumbnails — a PURE storage layer (no generation,
/// no concurrency policy; `MediaArtworkProvider` owns those).
///
/// New writes are HEIC (`.heic`) — a video frame / sidecar poster is a photographic still, which the
/// lossy codec stores a fraction of the size PNG's lossless coder would. `existing(for:)` checks
/// `.heic` first, then falls back to a legacy `.png` from before the codec switch: regenerating a
/// whole wall at ~11s/tile over VPN just because the extension changed would be hostile, so the PNGs
/// are read as-is and retired naturally by LRU eviction. This is a DELIBERATE exception to
/// delete-over-deprecate — the cost of deletion falls on the user's bandwidth, not the codebase.
///
/// Three data kinds ride each key's base name:
///  - `.heic`/`.png` — the image itself (the eviction unit).
///  - `.dur` — the source duration in milliseconds (best-effort; absence just yields nil duration).
///  - `.fail` — a PERSISTENT failure marker (attempt count + last-attempt epoch) so a file libvlc
///    can't decode isn't re-attempted (and re-charged the full timeout) on every launch. The
///    size+mtime in the base name means a changed file self-invalidates its marker along with its
///    stale image. `MediaArtworkProvider` reads it to compute an exponential backoff.
///
/// Splitting `existing` (peek) from `store` (write) lets the caller distinguish a generation failure
/// (never calls `store`) from a write failure (`store` returns nil) — they must not be conflated, or
/// a write blip would poison a perfectly decodable file. The produced URL feeds `ArtworkSource.local(_:)`.
actor SMBThumbnailCache {
    private let directory: URL
    private let fileManager: FileManager

    /// Total cache-size ceiling. At ~30–120 KB per HEIC this holds several thousand thumbnails —
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

    /// The image extensions the cache reads, newest-codec first. `existing` probes them in order, so
    /// a key that has both (a legacy PNG never overwritten by a later HEIC store) resolves to the
    /// HEIC and the PNG ages out via LRU.
    private static let imageExtensions = ["heic", "png"]

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

    /// The cached thumbnail for `key` if a file already exists, else nil. Never generates. Probes
    /// `.heic` then legacy `.png`; the returned record carries the duration read from the base name's
    /// `.dur` sidecar (nil if absent).
    ///
    /// On a hit it stamps the file's access date to now so `sweep()` can evict by TRUE recency: iOS
    /// does not bump a file's access time on a plain `stat`/read, so the cache must set it explicitly
    /// (the same technique Nuke's `DataCache` uses) — otherwise eviction silently degrades to
    /// oldest-written-first regardless of how often a thumbnail is actually viewed.
    func existing(for key: SMBThumbnailKey) -> CachedThumbnail? {
        let base = baseName(for: key)
        for ext in Self.imageExtensions {
            let url = directory.appendingPathComponent("\(base).\(ext)")
            guard fileManager.fileExists(atPath: url.path) else { continue }
            touchAccessDate(url)
            return CachedThumbnail(url: url, duration: readDuration(base: base))
        }
        return nil
    }

    /// Writes `data` as the `.heic` thumbnail for `key` (plus `duration` as a `.dur` sidecar when
    /// present), returning the cached record, or nil if the image write fails (createDirectory /
    /// atomic-write error). A nil here means a STORAGE failure, NOT a generation failure — the caller
    /// already produced valid bytes — so the caller must not treat it as a reason to negative-cache
    /// the key. No partial file is left behind on failure. A successful write CLEARS any persistent
    /// `.fail` marker for the key (the file just proved decodable).
    func store(_ data: Data, duration: Duration?, for key: SMBThumbnailKey) -> CachedThumbnail? {
        let base = baseName(for: key)
        let url = directory.appendingPathComponent("\(base).heic")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        // A decodable file: drop any stale failure marker so its backoff doesn't linger.
        removeFailure(base: base)
        // Persist the duration sidecar and report back ONLY what actually reached disk: a failed
        // sidecar write (or no duration) means a later `existing(for:)` reads nil, so store() must
        // return nil too — otherwise the same key shows a duration now and none after a
        // scroll-off/scroll-back. Re-storing a key without a duration also clears any stale sidecar.
        let persistedDuration: Duration?
        if let duration, writeDuration(duration, base: base) {
            persistedDuration = duration
        } else {
            removeDuration(base: base)
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

    // MARK: - Failure markers

    /// The persistent failure state for `key`, or nil when no `.fail` marker exists (never failed,
    /// or a prior success cleared it, or the file changed so the new key reads a fresh base). The
    /// provider turns `attempts` into an exponential backoff (capped, never permanent).
    func failureState(for key: SMBThumbnailKey) -> (attempts: Int, lastAttempt: Date)? {
        failureState(at: failURL(base: baseName(for: key)))
    }

    private func failureState(at url: URL) -> (attempts: Int, lastAttempt: Date)? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // "attempts lastEpoch" — whitespace/newline separated (written as two lines).
        let fields = text.split(whereSeparator: { $0 == "\n" || $0 == " " })
        guard fields.count >= 2,
              let attempts = Int(fields[0]), attempts > 0,
              let epoch = TimeInterval(fields[1])
        else { return nil }
        return (attempts, Date(timeIntervalSince1970: epoch))
    }

    /// The last-attempt stamp inside a `.fail` marker, or nil if unreadable (an unreadable marker
    /// reads as fresh — never expire what can't be parsed, the write path will overwrite it).
    private func failMarkerStamp(at url: URL) -> Date? {
        failureState(at: url)?.lastAttempt
    }

    /// Records one more generation failure for `key`: increments the attempt count and stamps the
    /// current epoch. Returns the state just recorded so the caller's in-memory mirror adopts the
    /// SAME count — the disk marker is the single source of truth for attempts (a memory-seeded
    /// count would restart at 1 after a relaunch and let a permanently-poisoned key retry forever).
    /// Best-effort on disk — a write failure just means no persisted backoff, but the returned
    /// count still reflects the increment so the in-session mirror stays coherent.
    @discardableResult
    func recordFailure(for key: SMBThumbnailKey) -> (attempts: Int, lastAttempt: Date) {
        let base = baseName(for: key)
        let attempts = (failureState(for: key)?.attempts ?? 0) + 1
        let stamp = Date()
        let epoch = Int64(stamp.timeIntervalSince1970.rounded())
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(attempts)\n\(epoch)".utf8).write(to: failURL(base: base), options: .atomic)
        } catch {
            // Non-actionable: a marker that didn't land just means no persisted backoff next launch.
        }
        return (attempts, stamp)
    }

    /// Allocated size of every cached file (images + `.dur`/`.fail` sidecars), for a "Clear Cache"
    /// readout. 0 when the directory doesn't exist yet (SMB never browsed) or can't be listed.
    func totalSize() -> Int64 {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            return sum + Int64(size)
        }
    }

    /// Wipes the whole cache directory (images + `.dur`/`.fail` sidecars). `store` recreates it on the
    /// next write. Re-arms the first-write sweep so a freshly-refilled cache is bounded from the next
    /// launch, and drops every failure marker so previously-undecodable files get a fresh attempt.
    func clear() {
        try? fileManager.removeItem(at: directory)
        writesSinceSweep = sweepInterval
    }

    // MARK: - Sidecars

    /// The `.dur` sidecar URL for a key's base name (`<base>.dur`). Holds the source duration in
    /// whole milliseconds as decimal text.
    private func durationSidecarURL(base: String) -> URL {
        directory.appendingPathComponent("\(base).dur")
    }

    /// The `.fail` marker URL for a key's base name (`<base>.fail`).
    private func failURL(base: String) -> URL {
        directory.appendingPathComponent("\(base).fail")
    }

    /// Reads the duration from the base name's sidecar, or nil if it's missing/unparseable.
    private func readDuration(base: String) -> Duration? {
        guard let data = try? Data(contentsOf: durationSidecarURL(base: base)),
              let text = String(data: data, encoding: .utf8),
              let milliseconds = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              milliseconds > 0
        else { return nil }
        return .milliseconds(milliseconds)
    }

    /// Writes the duration sidecar (whole milliseconds), returning whether it reached disk. A
    /// non-positive duration or a write error yields false, and `store` then reports a nil duration
    /// so its in-memory result can't disagree with a later on-disk `existing(for:)` read.
    private func writeDuration(_ duration: Duration, base: String) -> Bool {
        let milliseconds = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else { return false }
        do {
            try Data(String(milliseconds).utf8).write(to: durationSidecarURL(base: base), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes a base name's `.dur` sidecar if present (best-effort). Pairs with image eviction in
    /// `sweep` and clears a stale sidecar when a key is re-stored without a duration.
    private func removeDuration(base: String) {
        try? fileManager.removeItem(at: durationSidecarURL(base: base))
    }

    /// Removes a base name's `.fail` marker if present (best-effort).
    private func removeFailure(base: String) {
        try? fileManager.removeItem(at: failURL(base: base))
    }

    /// Stamps `url`'s access date to now so a hit counts as "recently used" for `sweep()`.
    private func touchAccessDate(_ url: URL) {
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// A `.fail` marker whose last attempt is older than this is inert history (the provider's
    /// backoff caps at 24h) and gets swept. Without this, a marker for a file that was deleted or
    /// changed server-side would live forever: a NEW size/mtime mints a NEW base name, so the old
    /// marker is orphaned by the change, not cleared by it.
    private static let failMarkerTTL: TimeInterval = 7 * 24 * 3600

    /// Bounded-LRU eviction plus `.fail` hygiene. Lists the cache directory once for size + access
    /// time; if the total exceeds `sizeCapBytes`, deletes least-recently-accessed IMAGE files until
    /// under `trimTargetBytes`. Access time is meaningful because `existing` stamps it on every hit.
    /// Independently drops `.fail` markers past `failMarkerTTL` — a still-failing file re-records
    /// (refreshing its stamp), so only abandoned markers age out. Best-effort: a transient
    /// list/remove failure just defers to the next sweep.
    private func sweep() {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, accessed: Date)] = []
        var total: Int64 = 0
        let now = Date()
        for entry in entries {
            // Images (heic + legacy png) are the eviction units; `.dur`/`.fail` sidecars are tiny and
            // ride their image out (below), so they're neither counted toward the cap nor evicted on
            // their own — except an EXPIRED `.fail`, dropped here so never-stored keys' markers
            // can't accumulate forever.
            if entry.pathExtension == "fail" {
                if let stamp = failMarkerStamp(at: entry), now.timeIntervalSince(stamp) > Self.failMarkerTTL {
                    try? fileManager.removeItem(at: entry)
                }
                continue
            }
            guard Self.imageExtensions.contains(entry.pathExtension) else { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            files.append((entry, size, values.contentAccessDate ?? .distantPast))
            total += size
        }

        guard total > sizeCapBytes else { return }

        // Oldest access first → evict until under the trim target. Each image takes its sidecars with it.
        files.sort { $0.accessed < $1.accessed }
        for file in files where total > trimTargetBytes {
            if (try? fileManager.removeItem(at: file.url)) != nil {
                total -= file.size
                let base = (file.url.lastPathComponent as NSString).deletingPathExtension
                removeDuration(base: base)
                removeFailure(base: base)
            }
        }
    }

    /// `<sha256(serverID + share + path)>-<size>-<mtimeEpoch>` — the shared base name for a key's
    /// image + `.dur` + `.fail` files. Hashing the server id, the share, and the path keeps two
    /// shares' (or two servers') identical relative paths in distinct cache files; the size +
    /// modification-date suffix means a changed file never collides with its own stale entry. The NUL
    /// separator can't appear in a host id, a share name, or a filename, so the digest input is
    /// unambiguous.
    private func baseName(for key: SMBThumbnailKey) -> String {
        let hash = Data("\(key.serverID)\u{0}\(key.share)\u{0}\(key.path)".utf8).sha256Hex
        let mtime = key.modifiedAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "na"
        return "\(hash)-\(key.size)-\(mtime)"
    }
}

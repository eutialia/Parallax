import Foundation

/// What a snapshot file holds. One value per cached payload shape — the store itself is generic,
/// so a new cached surface adds a case here and a typed accessor (see `MediaSnapshots`), never a
/// second persistence implementation.
public struct SnapshotKind: Sendable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// One server's Home feed slice — hero + Continue Watching + Next Up.
    public static let homeFeed = SnapshotKind(rawValue: "home-feed")
    /// One server's library collections, exactly as the server listed them (unfiltered: the
    /// hidden-libraries and browsable filters are applied on read, so changing them doesn't
    /// need the cache re-fetched).
    public static let libraries = SnapshotKind(rawValue: "libraries")
}

/// Stale-while-revalidate payload cache: the last known-good response for a surface, written
/// atomically to Application Support so the next launch can present real content immediately
/// instead of a skeleton, then replace it over the network.
///
/// One generic store backs every cached surface. Files live at
/// `<container>/v<schemaVersion>/<kind>/<sha256(serverID)>.json`, which makes the schema version
/// part of the *path*: a bumped version simply can't see the old files (they're pruned on first
/// use), and the presence probe stays a file-existence check rather than a decode. A file that
/// exists but no longer decodes — a model whose shape drifted without a version bump, a truncated
/// write — is discarded and deleted on read. Nothing here ever throws: a cache is an optimization,
/// and a failed read or write must degrade to today's network-only behavior, never to an error the
/// UI has to render.
///
/// Keyed by server id, so a removed / signed-out server's cache goes with it (`ServerStore` calls
/// `removeSnapshots(forServerID:)` from both paths).
public actor SnapshotStore {
    /// Bump to discard every snapshot written by an older build — the escape hatch for a payload
    /// shape change that a decode failure alone wouldn't catch (same fields, different meaning).
    public static let schemaVersion = 1

    /// `nonisolated let` so the synchronous presence probe can read it: the probe runs at app
    /// init, before any async work, and must not require an actor hop.
    private nonisolated let container: URL
    private nonisolated let versionRoot: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var didPruneStaleVersions = false
    private var didExcludeFromBackup = false

    /// - Parameters:
    ///   - container: the directory holding every schema version's snapshots. Defaults to
    ///     `Application Support/Snapshots`; tests pass a temporary directory.
    ///   - schemaVersion: the version directory to read and write. Defaults to the current
    ///     schema; tests use it to prove an older version's files are invisible.
    public init(container: URL? = nil, schemaVersion: Int = SnapshotStore.schemaVersion) {
        let root = container ?? URL.applicationSupportDirectory.appending(
            path: "Snapshots", directoryHint: .isDirectory
        )
        self.container = root
        self.versionRoot = root.appending(path: "v\(schemaVersion)", directoryHint: .isDirectory)
    }

    // MARK: - Reading

    /// The cached payload for this server, or nil when nothing usable is stored. A file that fails
    /// to decode is deleted so the next launch doesn't pay for it again.
    public func load<Payload: Codable & Sendable>(
        _ type: Payload.Type = Payload.self,
        kind: SnapshotKind,
        serverID: String
    ) -> Payload? {
        pruneStaleVersionsIfNeeded()
        let url = fileURL(kind: kind, serverID: serverID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            Log.persistence.info("SnapshotStore: discarding an undecodable \(kind.rawValue) snapshot")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return payload
    }

    // MARK: - Writing

    /// Replaces this server's cached payload. Best-effort: a write failure is logged and dropped,
    /// leaving the previous snapshot (or none) in place.
    public func save<Payload: Codable & Sendable>(
        _ payload: Payload,
        kind: SnapshotKind,
        serverID: String
    ) {
        pruneStaleVersionsIfNeeded()
        do {
            let directory = directory(for: kind)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(payload).write(to: fileURL(kind: kind, serverID: serverID), options: .atomic)
            excludeContainerFromBackup()
        } catch {
            Log.persistence.error("SnapshotStore: \(kind.rawValue) write failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Invalidation

    /// Drops every kind of snapshot held for one server — the counterpart to removing or signing
    /// out of it. Silent: the server is already gone, and a leftover file only wastes a few KB
    /// until the next write.
    public func removeSnapshots(forServerID serverID: String) {
        let kinds = (try? FileManager.default.contentsOfDirectory(
            at: versionRoot, includingPropertiesForKeys: nil
        )) ?? []
        for kind in kinds {
            try? FileManager.default.removeItem(
                at: kind.appending(path: fileName(for: serverID), directoryHint: .notDirectory)
            )
        }
    }

    // MARK: - Presence probe

    /// Whether any server has a snapshot of this kind — a directory listing, no decode, callable
    /// synchronously at app init before any async work. Answers "is there cached content to show
    /// at launch?": snapshots are removed with their server, so a file here always belongs to a
    /// currently persisted one, and the schema version is part of the path, so an old build's
    /// files are never counted.
    public nonisolated func hasAnySnapshot(kind: SnapshotKind) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: directory(for: kind).path(percentEncoded: false)
        )) ?? []
        return entries.contains { $0.hasSuffix(".json") }
    }

    // MARK: - Layout

    private nonisolated func directory(for kind: SnapshotKind) -> URL {
        versionRoot.appending(path: kind.rawValue, directoryHint: .isDirectory)
    }

    private nonisolated func fileURL(kind: SnapshotKind, serverID: String) -> URL {
        directory(for: kind).appending(path: fileName(for: serverID), directoryHint: .notDirectory)
    }

    /// Server ids are user-derived (`smb-<host>`) and can hold path separators, so they're hashed
    /// rather than sanitized — a sanitizer that maps two ids to one name would serve one server's
    /// Home feed to another.
    private nonisolated func fileName(for serverID: String) -> String {
        "\(Data(serverID.utf8).sha256Hex).json"
    }

    /// Deletes every other schema version's directory the first time this store touches disk.
    /// Old snapshots are unreachable by path anyway; removing them keeps a version bump from
    /// leaving a permanent copy of a dead schema on the device.
    private func pruneStaleVersionsIfNeeded() {
        guard !didPruneStaleVersions else { return }
        didPruneStaleVersions = true
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil
        )) ?? []
        for version in versions where version.lastPathComponent != versionRoot.lastPathComponent {
            try? FileManager.default.removeItem(at: version)
        }
    }

    /// Snapshots are regenerable network content — backing them up (and restoring them onto
    /// another device) buys nothing and inflates every backup. Once per store: the flag is a
    /// directory attribute, not something a later write can undo.
    private func excludeContainerFromBackup() {
        guard !didExcludeFromBackup else { return }
        didExcludeFromBackup = true
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = container
        try? url.setResourceValues(values)
    }
}

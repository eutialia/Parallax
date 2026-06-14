import Foundation
import ParallaxCore

public actor ServerStore {
    public enum ServerStoreError: Error, Sendable {
        case persistenceFailed(underlying: String)
        case decodeFailed(underlying: String)
    }

    /// The legacy v1 on-disk shape: a flat Jellyfin-only record. Kept ONLY as
    /// the migration-input type — `load()` falls back to decoding this when the
    /// current `[PersistedServer]` shape fails, then rewrites it as `.jellyfin`.
    /// Not part of the live API; nothing constructs it.
    private struct LegacyPersistedSession: Codable {
        let id: ServerID
        let serverURL: URL
        let serverName: String
        let user: UserSnapshot
    }

    private static let persistedServersKey = SettingKey<[PersistedServer]>(
        name: "ParallaxJellyfin.persistedSessions",
        defaultValue: []
    )
    private static let legacyPersistedSessionsKey = SettingKey<[LegacyPersistedSession]>(
        name: "ParallaxJellyfin.persistedSessions",
        defaultValue: []
    )
    private static let activeServerIDKey = SettingKey<String?>(
        name: "ParallaxJellyfin.activeServerID",
        defaultValue: nil
    )

    private let settings: SettingsStore
    private let keychain: any KeychainStoring
    private var persistedServers: [PersistedServer] = []
    private var loadedSessions: [Session] = []
    private var activeID: ServerID?

    public init(settings: SettingsStore, keychain: any KeychainStoring) {
        self.settings = settings
        self.keychain = keychain
    }

    /// Every persisted server, regardless of kind (Jellyfin sessions + SMB
    /// servers). `sessions` is the Jellyfin-only subset that has a live token.
    public var servers: [PersistedServer] { persistedServers }

    public var sessions: [Session] { loadedSessions }

    public var active: Session? {
        guard let activeID else { return loadedSessions.first }
        return loadedSessions.first(where: { $0.id == activeID })
    }

    public func load() async throws {
        let servers = try await loadPersistedServers()
        persistedServers = servers

        var rebuilt: [Session] = []
        var orphanedJellyfinIDs: Set<ServerID> = []
        for server in servers {
            // Only `.jellyfin` servers reconstruct into a `Session`; their
            // Keychain slot holds the bearer token. SMB servers persist but
            // have no session (their slot holds the password, used at connect).
            guard case .jellyfin = server.kind else { continue }
            let key = KeychainKey<String>(account: tokenAccount(for: server.id))
            do {
                if let token = try await keychain.read(key),
                   let session = Session(persisted: server, accessToken: token) {
                    rebuilt.append(session)
                } else {
                    // Token is confirmed ABSENT (Keychain returned nil) — the
                    // user signed out / the slot was wiped. Safe to prune.
                    orphanedJellyfinIDs.insert(server.id)
                }
            } catch {
                // A Keychain READ ERROR (locked device, missing entitlement) is
                // NOT proof the token is gone — pruning here would permanently
                // lose the saved server over a transient fault. Skip building a
                // session this load; leave the persisted record untouched.
                Log.persistence.error("ServerStore.load: Keychain read failed for \(server.id.rawValue) — leaving persisted record intact. \(error.localizedDescription)")
            }
        }
        loadedSessions = rebuilt

        if !orphanedJellyfinIDs.isEmpty {
            // Drop the orphaned Jellyfin servers (token confirmed gone) while
            // keeping every other server (SMB, and Jellyfin servers that still
            // resolve or that we couldn't read this launch).
            persistedServers.removeAll { orphanedJellyfinIDs.contains($0.id) }
            do {
                try await settings.set(persistedServers, for: Self.persistedServersKey)
            } catch {
                throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
            }
        }

        let storedActive = await settings.value(for: Self.activeServerIDKey)
        if let rawID = storedActive {
            let id = ServerID(rawValue: rawID)
            if rebuilt.contains(where: { $0.id == id }) {
                activeID = id
            } else {
                activeID = rebuilt.first?.id
                try await persistActiveID()
            }
        } else {
            activeID = rebuilt.first?.id
        }
    }

    /// Decodes the persisted server list, migrating the legacy flat shape on
    /// the fly. Tries the current `[PersistedServer]` shape first; on decode
    /// failure, falls back to the legacy `[LegacyPersistedSession]` shape,
    /// rewrites each entry as `.jellyfin`, persists the upgraded form, and
    /// returns it. Throws `decodeFailed` only when BOTH shapes fail — refusing
    /// to wipe (which would orphan Keychain tokens / log the user out).
    private func loadPersistedServers() async throws -> [PersistedServer] {
        do {
            return try await settings.tryValue(for: Self.persistedServersKey) ?? []
        } catch let newShapeError {
            let legacy: [LegacyPersistedSession]
            do {
                legacy = try await settings.tryValue(for: Self.legacyPersistedSessionsKey) ?? []
            } catch {
                // Both the current and the legacy shape failed to decode — a
                // genuine schema mismatch we can't recover. Refuse to wipe.
                Log.persistence.error("ServerStore.load: persistedServers decode failed (new + legacy) — refusing to wipe. new=\(String(describing: newShapeError)) legacy=\(String(describing: error))")
                throw ServerStoreError.decodeFailed(underlying: String(describing: newShapeError))
            }

            let upgraded = legacy.map { entry in
                PersistedServer(
                    id: entry.id,
                    kind: .jellyfin(JellyfinServerData(
                        serverURL: entry.serverURL,
                        serverName: entry.serverName,
                        user: entry.user
                    ))
                )
            }
            Log.persistence.info("ServerStore.load: migrated \(upgraded.count) legacy Jellyfin session(s) to PersistedServer")
            do {
                try await settings.set(upgraded, for: Self.persistedServersKey)
            } catch {
                throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
            }
            return upgraded
        }
    }

    /// Adds (or replaces) a session. Coordinates the two stores so a partial
    /// failure does not leave a Keychain token orphaned: on settings.set
    /// failure we restore the previous Keychain entry (or delete the new
    /// one for a fresh add) and revert the in-memory list.
    public func add(_ session: Session) async throws {
        let key = KeychainKey<String>(account: tokenAccount(for: session.id))
        let existingIndex = loadedSessions.firstIndex(where: { $0.id == session.id })
        let previousToken: String? = existingIndex.map { loadedSessions[$0].accessToken }
        let previousSessions = loadedSessions
        let previousServers = persistedServers

        do {
            try await keychain.store(session.accessToken, for: key)
        } catch {
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        if let existingIndex {
            loadedSessions[existingIndex] = session
        } else {
            loadedSessions.append(session)
        }
        if let serverIndex = persistedServers.firstIndex(where: { $0.id == session.id }) {
            persistedServers[serverIndex] = session.persisted
        } else {
            persistedServers.append(session.persisted)
        }

        do {
            try await settings.set(persistedServers, for: Self.persistedServersKey)
        } catch {
            // Roll back Keychain so we never leave a live token unreferenced
            // by UserDefaults. Best-effort: log restore failure but surface
            // the original error so the caller knows the add did not commit.
            await rollbackKeychain(key: key, previousToken: previousToken)
            loadedSessions = previousSessions
            persistedServers = previousServers
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        if activeID == nil {
            do {
                activeID = session.id
                try await persistActiveID()
            } catch {
                // activeID write failure is non-fatal for the add — the
                // token + persisted session are committed; on next load
                // the first session becomes active by default.
                Log.persistence.error("ServerStore.add: activeID persist failed — \(error.localizedDescription)")
                activeID = nil
            }
        }
    }

    /// Removes a session. If the Keychain delete fails we throw without
    /// touching UserDefaults — better to leave the user with a visible
    /// (and removable) session than to silently orphan a live token.
    public func remove(_ id: ServerID) async throws {
        let key = KeychainKey<String>(account: tokenAccount(for: id))
        do {
            try await keychain.delete(key)
        } catch {
            // Keychain.delete already treats errSecItemNotFound as success,
            // so reaching here is a genuine failure. Refuse to prune.
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        let previousSessions = loadedSessions
        let previousServers = persistedServers
        let previousActive = activeID
        loadedSessions.removeAll(where: { $0.id == id })
        persistedServers.removeAll(where: { $0.id == id })

        do {
            try await settings.set(persistedServers, for: Self.persistedServersKey)
        } catch {
            loadedSessions = previousSessions
            persistedServers = previousServers
            activeID = previousActive
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        if activeID == id {
            activeID = loadedSessions.first?.id
            do {
                try await persistActiveID()
            } catch {
                Log.persistence.error("ServerStore.remove: activeID persist failed — \(error.localizedDescription)")
            }
        }
    }

    public func setActive(_ id: ServerID) async throws {
        guard loadedSessions.contains(where: { $0.id == id }) else { return }
        activeID = id
        try await persistActiveID()
    }

    private func rollbackKeychain(key: KeychainKey<String>, previousToken: String?) async {
        do {
            if let previousToken {
                try await keychain.store(previousToken, for: key)
            } else {
                try await keychain.delete(key)
            }
        } catch {
            Log.persistence.error("ServerStore.add rollback failed — token may be orphaned. \(error.localizedDescription)")
        }
    }

    private func persistActiveID() async throws {
        do {
            try await settings.set(activeID?.rawValue, for: Self.activeServerIDKey)
        } catch {
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }
    }

    private func tokenAccount(for id: ServerID) -> String {
        "token-\(id.rawValue)"
    }
}

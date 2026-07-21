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

    /// Decodes `T` but never fails the enclosing container: an element whose
    /// shape no longer matches `T` decodes to `nil` instead of throwing, so a
    /// single incompatible row can't take the whole array down. Used by the
    /// element-tolerant decode fallback in `loadPersistedServers()`. `Sendable`
    /// (immutable `value`) so a `[Failable<T>]` can cross the `SettingsStore`
    /// actor boundary.
    private struct Failable<T: Decodable & Sendable>: Decodable, Sendable {
        let value: T?
        init(from decoder: any Decoder) throws {
            value = try? T(from: decoder)
        }
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
    /// Per-server hidden library collections, keyed by `serverID.rawValue` → the collection IDs the
    /// user has de-selected on that server's "Visible Libraries" screen. Encoded as arrays for stable
    /// JSON; held as sets in memory. Absent / empty = every library visible.
    private static let hiddenCollectionsKey = SettingKey<[String: [String]]>(
        name: "ParallaxJellyfin.hiddenCollections",
        defaultValue: [:]
    )

    private let settings: SettingsStore
    private let keychain: any KeychainStoring
    private var persistedServers: [PersistedServer] = []
    private var loadedSessions: [Session] = []
    private var activeID: ServerID?
    private var hiddenCollections: [String: Set<String>] = [:]

    public init(settings: SettingsStore, keychain: any KeychainStoring) {
        self.settings = settings
        self.keychain = keychain
    }

    /// Every persisted server, regardless of kind (Jellyfin sessions + SMB
    /// servers). `sessions` is the Jellyfin-only subset that has a live token.
    public var servers: [PersistedServer] { persistedServers }

    public var sessions: [Session] { loadedSessions }

    /// Jellyfin servers whose persisted row exists but whose token couldn't be rebuilt into a
    /// session this launch (Keychain slot lost or unreadable). Surfaced so Settings can render
    /// them as signed-out instead of letting them ghost invisibly; re-signing-in heals the row
    /// in place (deterministic server id → `add` replaces), `remove(_:)` discards it.
    public var signedOutJellyfinServers: [PersistedServer] {
        persistedServers.filter { server in
            guard case .jellyfin = server.kind else { return false }
            return !loadedSessions.contains { $0.id == server.id }
        }
    }

    /// Whether any SMB server is configured. The app's router folds this into its
    /// login-vs-home decision: an SMB server with no Jellyfin session is still a
    /// browsable home, not a login dead-end.
    public var hasSMBServers: Bool {
        persistedServers.contains { if case .smb = $0.kind { return true }; return false }
    }

    public var active: Session? {
        guard let activeID else { return loadedSessions.first }
        return loadedSessions.first(where: { $0.id == activeID })
    }

    /// The library collection IDs hidden on a server (empty = all visible). Read by the navigation
    /// roots to filter the merged library and by the "Visible Libraries" screen to seed its toggles.
    public func hiddenCollectionIDs(for id: ServerID) -> Set<String> {
        hiddenCollections[id.rawValue] ?? []
    }

    /// Replace a server's hidden-collections set and persist it. An empty set drops the server's entry
    /// entirely (keeps the stored dict tidy). Callers bump the router's library revision afterward so
    /// the roots rebuild the merged list.
    public func setHiddenCollectionIDs(_ ids: Set<String>, for id: ServerID) async throws {
        if ids.isEmpty {
            hiddenCollections.removeValue(forKey: id.rawValue)
        } else {
            hiddenCollections[id.rawValue] = ids
        }
        do {
            try await settings.set(hiddenCollections.mapValues(Array.init), for: Self.hiddenCollectionsKey)
        } catch {
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }
    }

    public func load() async throws {
        let servers = try await loadPersistedServers()
        persistedServers = servers

        var rebuilt: [Session] = []
        for server in servers {
            // Only `.jellyfin` servers reconstruct into a `Session`; their
            // Keychain slot holds the bearer token. SMB servers persist but
            // have no session (their slot holds the password, used at connect).
            guard case .jellyfin = server.kind else { continue }
            let key = KeychainKey<String>(account: Self.tokenAccount(for: server.id))
            do {
                if let token = try await keychain.read(key),
                   let session = Session(persisted: server, accessToken: token) {
                    rebuilt.append(session)
                } else {
                    // Token absent. This is NEVER a completed sign-out — signOut goes through
                    // `remove(_:)`, which deletes the row along with the token — so a token-less
                    // row means the Keychain lost data underneath us (access-group change after a
                    // bundle-id rename, device migration with ThisDeviceOnly items). Keep the row:
                    // it surfaces via `signedOutJellyfinServers`, and re-signing-in heals it in
                    // place (deterministic server id → `add` replaces). Pruning here once turned
                    // exactly this fault into a silently vanished server.
                    Log.persistence.error("ServerStore.load: token missing for \(server.id.rawValue) — keeping row as signed-out")
                }
            } catch {
                // A Keychain READ ERROR (locked device, missing entitlement) is
                // NOT proof the token is gone. Skip building a session this
                // load; leave the persisted record untouched.
                Log.persistence.error("ServerStore.load: Keychain read failed for \(server.id.rawValue) — leaving persisted record intact. \(error.localizedDescription)")
            }
        }
        loadedSessions = rebuilt

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

        hiddenCollections = (await settings.value(for: Self.hiddenCollectionsKey)).mapValues(Set.init)
    }

    /// Decodes the persisted server list across three fallbacks, ordered so the
    /// safest interpretation always wins:
    ///
    /// 1. **Strict `[PersistedServer]`** — the current shape; the common path.
    /// 2. **Legacy `[LegacyPersistedSession]`** — a genuine v1 flat array (no
    ///    `kind` field); migrated to `.jellyfin`, persisted upgraded, returned.
    /// 3. **Element-tolerant `[PersistedServer]`** — the current shape decoded
    ///    per-element via `Failable`, dropping only the rows that no longer match
    ///    (e.g. pre-release SMB rows from the old host/share/root model) while
    ///    keeping every still-valid Jellyfin/SMB row; the cleaned array is
    ///    persisted so the next launch re-reads cleanly.
    ///
    /// Order is load-bearing: the legacy pass MUST precede the tolerant pass.
    /// A v1 flat array fed to the tolerant `[Failable<PersistedServer>]` decoder
    /// would yield all-`nil` (no `kind` field on any element) and silently wipe a
    /// v1 Jellyfin user; running legacy first migrates them correctly instead.
    /// As a second guard, the tolerant pass commits ONLY when it keeps at least
    /// one row — an all-dropped result is indistinguishable from "not a new-shape
    /// array" (e.g. a partially-corrupt v1 blob), so it falls through to
    /// `decodeFailed` rather than persisting an empty array over recoverable data.
    /// `decodeFailed` is thrown only when ALL THREE fail — never wiping a blob we
    /// could still partially recover.
    private func loadPersistedServers() async throws -> [PersistedServer] {
        do {
            return try await settings.tryValue(for: Self.persistedServersKey) ?? []
        } catch let newShapeError {
            // Fallback 2: a genuine v1 legacy array (flat Jellyfin, no `kind`).
            if let upgraded = try await migrateLegacyShapeIfPossible() {
                return upgraded
            }

            // Fallback 3: element-tolerant decode of the CURRENT shape. This drops
            // entries whose kind no longer matches (e.g. pre-release SMB rows from
            // the old host/share/root model) while keeping every still-valid row.
            // Decoded as `[Failable<PersistedServer>]` over the SAME key's raw bytes
            // via `settings.decode`, so a bad element becomes `nil` instead of failing
            // the array — reusing the store's `JSONDecoder`, no separate key needed.
            // Commits only with ≥1 survivor: an all-dropped result is not a safe
            // signal to wipe (it could be a v1 array the legacy pass couldn't fully
            // decode), so we leave the blob and fall through to `decodeFailed`.
            if let failable = await settings.decode([Failable<PersistedServer>].self, for: Self.persistedServersKey) {
                let survivors = failable.compactMap(\.value)
                if !survivors.isEmpty {
                    let dropped = failable.count - survivors.count
                    Log.persistence.info("ServerStore.load: tolerant decode kept \(survivors.count) of \(failable.count) persisted server(s), dropped \(dropped)")
                    do {
                        try await settings.set(survivors, for: Self.persistedServersKey)
                    } catch {
                        throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
                    }
                    return survivors
                }
            }

            // All three shapes failed to decode (or tolerant salvaged nothing) — a
            // genuine schema mismatch we can't safely recover. Refuse to wipe (which
            // would orphan Keychain tokens / log the user out).
            Log.persistence.error("ServerStore.load: persistedServers decode failed (strict + legacy + tolerant) — refusing to wipe. \(String(describing: newShapeError))")
            throw ServerStoreError.decodeFailed(underlying: String(describing: newShapeError))
        }
    }

    /// Attempts the v1 legacy migration: decodes the blob as the flat
    /// `[LegacyPersistedSession]` shape, rewrites each entry as `.jellyfin`,
    /// persists the upgraded form, and returns it. Returns `nil` when the blob is
    /// NOT the legacy shape (decode throws) so the caller can try the next
    /// fallback. Throws only on a persistence write failure.
    private func migrateLegacyShapeIfPossible() async throws -> [PersistedServer]? {
        guard let legacy = try? await settings.tryValue(for: Self.legacyPersistedSessionsKey),
              !legacy.isEmpty else {
            return nil
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

    /// Adds (or replaces) a session. Coordinates the two stores so a partial
    /// failure does not leave a Keychain token orphaned: on settings.set
    /// failure we restore the previous Keychain entry (or delete the new
    /// one for a fresh add) and revert the in-memory list.
    public func add(_ session: Session) async throws {
        let key = KeychainKey<String>(account: Self.tokenAccount(for: session.id))
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
        let key = KeychainKey<String>(account: Self.tokenAccount(for: id))
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

        // Drop any per-server hidden-collections set so a later re-add of the same id can't inherit
        // stale visibility (a Jellyfin re-add reuses the deterministic id). Best-effort: the server is
        // already gone; a lingering entry only wastes a little storage until the next successful write.
        if hiddenCollections.removeValue(forKey: id.rawValue) != nil {
            do {
                try await settings.set(hiddenCollections.mapValues(Array.init), for: Self.hiddenCollectionsKey)
            } catch {
                Log.persistence.error("ServerStore.remove: hiddenCollections purge persist failed — \(error.localizedDescription)")
            }
        }
    }

    /// Persists a configured SMB server. The password goes to the SAME opaque
    /// Keychain slot Jellyfin uses for bearer tokens (`token-<id>`), so
    /// `remove(_:)` already cleans it up.
    ///
    /// The `ServerID` is derived deterministically from `host` as
    /// `"smb-\(host)"` — stable across re-adds, never collides with a Jellyfin id
    /// (which has no `smb-` prefix), and human-readable in logs. Re-adding the
    /// same host reuses the same id, so shares and credentials update in-place
    /// rather than duplicating the row.
    ///
    /// Does NOT touch `loadedSessions` and does NOT call `setActive` — SMB
    /// servers have no `Session`, and making one "active" would nil-route the
    /// Jellyfin-keyed router to the login screen.
    @discardableResult
    public func addSMBServer(_ data: SMBServerData, password: String) async throws -> ServerID {
        let id = ServerID(rawValue: "smb-\(data.host)")
        let key = KeychainKey<String>(account: Self.tokenAccount(for: id))

        // Capture previous state for rollback. A THROWN read (transient Keychain fault) is NOT
        // proof the slot is empty — distinguish it from a confirmed-absent slot so a re-add
        // never deletes a still-valid password: nil-because-absent is safe to delete on
        // rollback; a thrown read leaves the slot untouched.
        let previousServers = persistedServers
        let previousPassword: String?
        let slotWasConfirmedEmpty: Bool
        do {
            previousPassword = try await keychain.read(key)
            slotWasConfirmedEmpty = (previousPassword == nil)
        } catch {
            previousPassword = nil
            slotWasConfirmedEmpty = false
        }

        do {
            try await keychain.store(password, for: key)
        } catch {
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        let server = PersistedServer(id: id, kind: .smb(data))
        if let existingIndex = persistedServers.firstIndex(where: { $0.id == id }) {
            persistedServers[existingIndex] = server
        } else {
            persistedServers.append(server)
        }

        do {
            try await settings.set(persistedServers, for: Self.persistedServersKey)
        } catch {
            // Roll back Keychain and in-memory list so a settings failure never leaves a live
            // password unreferenced by UserDefaults. Restore a captured previous password;
            // delete ONLY if the slot was confirmed empty (a true fresh add). If the pre-read
            // threw, leave the slot — deleting could wipe a password that was actually there.
            if let previousPassword {
                try? await keychain.store(previousPassword, for: key)
            } else if slotWasConfirmedEmpty {
                try? await keychain.delete(key)
            }
            persistedServers = previousServers
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        return id
    }

    /// Replaces the selected `shares` on an already-persisted SMB server. No-op for an
    /// unknown id or a non-SMB server. Persists with the same revert-on-failure discipline
    /// as the other writers; the password slot is untouched.
    public func setShares(_ shares: [String], for id: ServerID) async throws {
        guard let index = persistedServers.firstIndex(where: { $0.id == id }),
              case .smb(let data) = persistedServers[index].kind else { return }
        let updated = SMBServerData(host: data.host, username: data.username, domain: data.domain, shares: shares)
        let previous = persistedServers
        persistedServers[index] = PersistedServer(id: id, kind: .smb(updated))
        do {
            try await settings.set(persistedServers, for: Self.persistedServersKey)
        } catch {
            persistedServers = previous
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
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

    /// The persisted SMB password for `id`. `addSMBServer` ALWAYS stores one — even a guest's
    /// empty string — so a clean Keychain miss means the slot was LOST (access-group change,
    /// device migration), never "no password": that's surfaced as `.auth(.credentialUnavailable)`
    /// instead of being degraded into an empty-password logon the server rejects with an error
    /// that reads as its fault (the live-NAS EPERM incident).
    public func smbPassword(for id: ServerID) async throws -> String {
        let key = KeychainKey<String>(account: Self.tokenAccount(for: id))
        let stored: String?
        do {
            stored = try await keychain.read(key)
        } catch {
            Log.persistence.error("ServerStore.smbPassword: Keychain read failed for \(id.rawValue) — \(error.localizedDescription)")
            throw AppError.unexpected("SMB password read failed", underlying: AnySendableError(error))
        }
        guard let stored else {
            Log.persistence.error("ServerStore.smbPassword: slot missing for \(id.rawValue)")
            throw AppError.auth(.credentialUnavailable)
        }
        return stored
    }

    /// The opaque Keychain account that holds a server's secret — the Jellyfin bearer token
    /// for `.jellyfin`, the password for `.smb`. Public + static so the app's media-repo
    /// factory and SMB playback resolver derive the SAME slot instead of re-hardcoding the
    /// `"token-<id>"` literal (a divergence would silently read an empty password and fail
    /// SMB auth with no error).
    public static func tokenAccount(for id: ServerID) -> String {
        "token-\(id.rawValue)"
    }
}

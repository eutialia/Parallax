import Foundation
import ParallaxCore

public actor ServerStore {
    public enum ServerStoreError: Error, Sendable {
        case persistenceFailed(underlying: String)
        case decodeFailed(underlying: String)
    }

    private static let persistedSessionsKey = SettingKey<[PersistedSession]>(
        name: "ParallaxJellyfin.persistedSessions",
        defaultValue: []
    )
    private static let activeServerIDKey = SettingKey<String?>(
        name: "ParallaxJellyfin.activeServerID",
        defaultValue: nil
    )

    private let settings: SettingsStore
    private let keychain: Keychain
    private var loadedSessions: [Session] = []
    private var activeID: ServerID?

    public init(settings: SettingsStore, keychain: Keychain) {
        self.settings = settings
        self.keychain = keychain
    }

    public var sessions: [Session] { loadedSessions }

    public var active: Session? {
        guard let activeID else { return loadedSessions.first }
        return loadedSessions.first(where: { $0.id == activeID })
    }

    public func load() async throws {
        let persisted: [PersistedSession]
        do {
            persisted = try await settings.tryValue(for: Self.persistedSessionsKey) ?? []
        } catch {
            // Decode failure on the session list means a schema mismatch
            // (added/changed field). Wiping would silently lose every saved
            // server AND orphan their Keychain tokens. Refuse loudly instead.
            Log.persistence.error("ServerStore.load: persistedSessions decode failed — refusing to wipe. \(String(describing: error))")
            throw ServerStoreError.decodeFailed(underlying: String(describing: error))
        }

        var rebuilt: [Session] = []
        var orphaned: [PersistedSession] = []
        for entry in persisted {
            let key = KeychainKey<String>(account: tokenAccount(for: entry.id))
            do {
                if let token = try await keychain.read(key) {
                    rebuilt.append(Session(persisted: entry, accessToken: token))
                } else {
                    orphaned.append(entry)
                }
            } catch {
                Log.persistence.error("ServerStore.load: Keychain read failed for \(entry.id.rawValue) — \(error.localizedDescription)")
                orphaned.append(entry)
            }
        }
        loadedSessions = rebuilt

        if !orphaned.isEmpty {
            do {
                try await settings.set(rebuilt.map(\.persisted), for: Self.persistedSessionsKey)
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

    /// Adds (or replaces) a session. Coordinates the two stores so a partial
    /// failure does not leave a Keychain token orphaned: on settings.set
    /// failure we restore the previous Keychain entry (or delete the new
    /// one for a fresh add) and revert the in-memory list.
    public func add(_ session: Session) async throws {
        let key = KeychainKey<String>(account: tokenAccount(for: session.id))
        let existingIndex = loadedSessions.firstIndex(where: { $0.id == session.id })
        let previousToken: String? = existingIndex.map { loadedSessions[$0].accessToken }
        let previousSessions = loadedSessions

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

        do {
            try await settings.set(loadedSessions.map(\.persisted), for: Self.persistedSessionsKey)
        } catch {
            // Roll back Keychain so we never leave a live token unreferenced
            // by UserDefaults. Best-effort: log restore failure but surface
            // the original error so the caller knows the add did not commit.
            await rollbackKeychain(key: key, previousToken: previousToken)
            loadedSessions = previousSessions
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
        let previousActive = activeID
        loadedSessions.removeAll(where: { $0.id == id })

        do {
            try await settings.set(loadedSessions.map(\.persisted), for: Self.persistedSessionsKey)
        } catch {
            loadedSessions = previousSessions
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

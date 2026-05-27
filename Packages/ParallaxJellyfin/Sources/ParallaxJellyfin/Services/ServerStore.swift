import Foundation
import ParallaxCore

public actor ServerStore {
    public enum ServerStoreError: Error, Sendable {
        case persistenceFailed(underlying: String)
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
        let persisted = await settings.value(for: Self.persistedSessionsKey)
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

    public func add(_ session: Session) async throws {
        let key = KeychainKey<String>(account: tokenAccount(for: session.id))
        do {
            try await keychain.store(session.accessToken, for: key)
        } catch {
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        if let existingIndex = loadedSessions.firstIndex(where: { $0.id == session.id }) {
            loadedSessions[existingIndex] = session
        } else {
            loadedSessions.append(session)
        }

        do {
            try await settings.set(loadedSessions.map(\.persisted), for: Self.persistedSessionsKey)
        } catch {
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        if activeID == nil {
            activeID = session.id
            try await persistActiveID()
        }
    }

    public func remove(_ id: ServerID) async throws {
        let key = KeychainKey<String>(account: tokenAccount(for: id))
        do {
            try await keychain.delete(key)
        } catch {
            Log.persistence.error("ServerStore.remove: Keychain delete failed for \(id.rawValue) — \(error.localizedDescription)")
        }

        loadedSessions.removeAll(where: { $0.id == id })

        do {
            try await settings.set(loadedSessions.map(\.persisted), for: Self.persistedSessionsKey)
        } catch {
            throw ServerStoreError.persistenceFailed(underlying: String(describing: error))
        }

        if activeID == id {
            activeID = loadedSessions.first?.id
            try await persistActiveID()
        }
    }

    public func setActive(_ id: ServerID) async throws {
        guard loadedSessions.contains(where: { $0.id == id }) else { return }
        activeID = id
        try await persistActiveID()
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

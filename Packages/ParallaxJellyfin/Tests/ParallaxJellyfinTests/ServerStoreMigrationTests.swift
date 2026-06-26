import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("ServerStore migration")
struct ServerStoreMigrationTests {
    /// The legacy v1 on-disk shape, reconstructed verbatim so the test pins the
    /// EXACT wire format an existing v1 user has in `UserDefaults`: a flat
    /// `{id, serverURL, serverName, user}` record. We encode a value of this
    /// shape with the same `JSONEncoder` `SettingsStore` uses, so the produced
    /// bytes are byte-for-byte what the shipped app wrote. (`PersistedSession`
    /// no longer exists as a public type — it's now a private legacy-decode
    /// shape inside `ServerStore` — so this mirror reproduces its layout. Its
    /// stored properties match 1:1, so synthesized `Codable` emits identical
    /// keys, including `ServerID`'s bare-string single-value encoding.)
    private struct LegacyPersistedSession: Codable {
        let id: ServerID
        let serverURL: URL
        let serverName: String
        let user: UserSnapshot
    }

    private static let persistedSessionsKeyName = "ParallaxJellyfin.persistedSessions"

    /// Captures the real legacy wire bytes by round-tripping a live value
    /// through the same encoder `SettingsStore` uses — never hand-authored JSON.
    private func legacyWireBytes(_ sessions: [LegacyPersistedSession]) throws -> Data {
        try JSONEncoder().encode(sessions)
    }

    private func seedLegacy(_ data: Data, suiteName: String) {
        let seeder = UserDefaults(suiteName: suiteName)!
        seeder.removePersistentDomain(forName: suiteName)
        seeder.set(data, forKey: Self.persistedSessionsKeyName)
        seeder.synchronize()
    }

    private func tokenKey(for id: ServerID) -> KeychainKey<String> {
        KeychainKey<String>(account: "token-\(id.rawValue)")
    }

    // MARK: - Pure persisted-shape migration

    /// THE high-risk assertion: an existing v1 user's stored blob must MIGRATE,
    /// not throw `decodeFailed` (which crashes them to the login screen). The
    /// `FakeKeychain` returns the bearer token for the migrated server, so the
    /// migrated record resolves and is RETAINED — deterministic on every
    /// runtime, including the unentitled package-test host (no `-34018`).
    @Test("Legacy PersistedSession blob migrates to a .jellyfin PersistedServer (no decodeFailed, no data loss)")
    func migratesLegacyShape() async throws {
        let suiteName = "ServerStoreMigrationTests-shape-\(UUID().uuidString)"
        let serverID = ServerID(rawValue: "legacy-server-1")
        let legacy = LegacyPersistedSession(
            id: serverID,
            serverURL: URL(string: "https://example.test")!,
            serverName: "Living Room",
            user: UserSnapshot(id: "user-42", name: "alice", serverLastUpdatedAt: nil)
        )
        seedLegacy(try legacyWireBytes([legacy]), suiteName: suiteName)

        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = SettingsStore(defaults: defaults)
        // Token present → the migrated server resolves and is kept.
        let keychain = FakeKeychain()
        try keychain.setValue("bearer-token-xyz", for: tokenKey(for: serverID))
        let store = ServerStore(settings: settings, keychain: keychain)

        // Must NOT throw — legacy users are not crashed out to login.
        try await store.load()

        let servers = await store.servers
        #expect(servers.count == 1)
        guard let first = servers.first, case .jellyfin(let j) = first.kind else {
            Issue.record("expected a single .jellyfin PersistedServer after migration")
            return
        }
        #expect(first.id == serverID)
        #expect(j.serverURL.absoluteString == "https://example.test")
        #expect(j.serverName == "Living Room")
        #expect(j.user.id == "user-42")
        #expect(j.user.name == "alice")

        // The upgraded shape was written back: the same key now re-reads cleanly
        // as the NEW type, so no second migration happens next launch.
        let reread = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let upgradedKey = SettingKey<[PersistedServer]>(
            name: Self.persistedSessionsKeyName,
            defaultValue: []
        )
        let upgraded = try await reread.tryValue(for: upgradedKey)
        #expect(upgraded?.count == 1)
        if case .jellyfin(let j2)? = upgraded?.first?.kind {
            #expect(j2.serverURL.absoluteString == "https://example.test")
        } else {
            Issue.record("re-read upgraded value did not decode as .jellyfin")
        }
    }

    @Test("Already-migrated PersistedServer blob loads unchanged (no re-migration)")
    func newShapeLoadsWithoutMigration() async throws {
        let suiteName = "ServerStoreMigrationTests-new-\(UUID().uuidString)"
        let serverID = ServerID(rawValue: "srv-new")
        let server = PersistedServer(
            id: serverID,
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://already.migrated")!,
                serverName: "New",
                user: UserSnapshot(id: "u", name: "bob", serverLastUpdatedAt: nil)
            ))
        )
        do {
            let seeder = UserDefaults(suiteName: suiteName)!
            seeder.removePersistentDomain(forName: suiteName)
            seeder.set(try JSONEncoder().encode([server]), forKey: Self.persistedSessionsKeyName)
            seeder.synchronize()
        }

        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let keychain = FakeKeychain()
        try keychain.setValue("tok", for: tokenKey(for: serverID))
        let store = ServerStore(settings: settings, keychain: keychain)
        try await store.load()

        let servers = await store.servers
        #expect(servers.count == 1)
        #expect(servers.first == server)
    }

    // MARK: - End-to-end no-logout (now deterministic via the fake)

    /// Proves the FULL no-logout guarantee: after migration the bearer token
    /// still resolves and the session rebuilds. With `FakeKeychain` the token
    /// read is deterministic, so this PASSES IN THE SIM — it is no longer part
    /// of the `errSecMissingEntitlement -34018` baseline.
    @Test("Old PersistedSession JSON migrates to .jellyfin PersistedServer, user stays logged in")
    func migratesLegacyJellyfinSession() async throws {
        let suiteName = "ServerStoreMigrationTests-token-\(UUID().uuidString)"
        let serverID = ServerID(rawValue: "legacy-server-1")
        let legacy = LegacyPersistedSession(
            id: serverID,
            serverURL: URL(string: "https://example.test")!,
            serverName: "Living Room",
            user: UserSnapshot(id: "user-42", name: "alice", serverLastUpdatedAt: nil)
        )
        seedLegacy(try legacyWireBytes([legacy]), suiteName: suiteName)

        let keychain = FakeKeychain()
        try keychain.setValue("bearer-token-xyz", for: tokenKey(for: serverID))

        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let store = ServerStore(settings: settings, keychain: keychain)
        try await store.load()

        let sessions = await store.sessions
        #expect(sessions.count == 1)
        #expect(sessions.first?.accessToken == "bearer-token-xyz")
        #expect(sessions.first?.serverURL.absoluteString == "https://example.test")
        #expect(sessions.first?.user.id == "user-42")
        // active session present → user NOT logged out.
        let active = await store.active
        #expect(active?.id == serverID)
    }

    // MARK: - load() token-resolution contracts

    /// A CONFIRMED-nil token read (the slot was wiped / user signed out) prunes
    /// the persisted Jellyfin server — both the in-memory record and its
    /// session disappear.
    @Test("Confirmed-nil Keychain token prunes the persisted Jellyfin server")
    func prunesServerOnConfirmedNilToken() async throws {
        let suiteName = "ServerStoreMigrationTests-prune-\(UUID().uuidString)"
        let serverID = ServerID(rawValue: "srv-prune")
        let server = PersistedServer(
            id: serverID,
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://prune.test")!,
                serverName: "Prune Me",
                user: UserSnapshot(id: "u", name: "carol", serverLastUpdatedAt: nil)
            ))
        )
        do {
            let seeder = UserDefaults(suiteName: suiteName)!
            seeder.removePersistentDomain(forName: suiteName)
            seeder.set(try JSONEncoder().encode([server]), forKey: Self.persistedSessionsKeyName)
            seeder.synchronize()
        }

        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let keychain = FakeKeychain()
        keychain.setAbsent(account: tokenKey(for: serverID).account)
        let store = ServerStore(settings: settings, keychain: keychain)
        try await store.load()

        let servers = await store.servers
        let sessions = await store.sessions
        #expect(servers.contains(where: { $0.id == serverID }) == false)
        #expect(sessions.isEmpty)

        // The prune was persisted back — the re-read blob no longer holds it.
        let reread = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingKey<[PersistedServer]>(name: Self.persistedSessionsKeyName, defaultValue: [])
        let persisted = try await reread.tryValue(for: key)
        #expect(persisted?.isEmpty == true)
    }

    // MARK: - Element-tolerant decode (drop incompatible pre-release SMB rows)

    /// A pre-release build could have written an SMB row in the OLD host/share/root
    /// shape (`{"smb":{"host","share","root",...}}`) that no longer decodes against
    /// the current `SMBServerData` (`host/username/domain/shares`). A single such
    /// element must NOT fail the whole array (which would log a valid Jellyfin user
    /// out): the tolerant pass drops the bad element and keeps every still-valid row,
    /// then persists the cleaned array so the next launch re-reads cleanly.
    ///
    /// The valid `.jellyfin` half is encoded from a real `PersistedServer` so its
    /// bytes are byte-faithful to what the app writes; only the deliberately
    /// incompatible old `.smb` half is hand-authored.
    @Test("load drops an old-shape SMB entry but keeps a valid Jellyfin entry")
    func tolerantDecodeDropsOldSMB() async throws {
        let suiteName = "ServerStoreMigrationTests-tolerant-\(UUID().uuidString)"
        let jellyfinID = ServerID(rawValue: "jf-1")
        let validJellyfin = PersistedServer(
            id: jellyfinID,
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://jf-1.example.com")!,
                serverName: "S",
                user: UserSnapshot(id: "u", name: "a", serverLastUpdatedAt: nil)
            ))
        )
        // Encode the valid element, then splice it into a two-element array whose
        // second element is the OLD-shape SMB row (share/root — no shares array).
        let validData = try JSONEncoder().encode(validJellyfin)
        let validString = String(decoding: validData, as: UTF8.self)
        let oldSMB = #"{"id":"smb-old","kind":{"smb":{"host":"nas","share":"Media","root":"/Movies","username":"a","domain":"W"}}}"#
        let json = "[\(validString),\(oldSMB)]"
        do {
            let seeder = UserDefaults(suiteName: suiteName)!
            seeder.removePersistentDomain(forName: suiteName)
            seeder.set(json.data(using: .utf8)!, forKey: Self.persistedSessionsKeyName)
            seeder.synchronize()
        }

        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let keychain = FakeKeychain()
        // Token present → the surviving Jellyfin server resolves and is kept.
        try keychain.setValue("bearer", for: tokenKey(for: jellyfinID))
        let store = ServerStore(settings: settings, keychain: keychain)

        // Must NOT throw — one bad element does not fail the array.
        try await store.load()

        let servers = await store.servers
        #expect(servers.count == 1)
        #expect(servers.first?.id == jellyfinID)
        #expect(servers.allSatisfy { if case .smb = $0.kind { return false }; return true })

        // The cleaned array was written back: the same key now re-reads as the
        // NEW type with the bad row already gone — no repeated salvage next launch.
        let reread = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingKey<[PersistedServer]>(name: Self.persistedSessionsKeyName, defaultValue: [])
        let persisted = try await reread.tryValue(for: key)
        #expect(persisted?.count == 1)
        #expect(persisted?.first?.id == jellyfinID)
    }

    /// Cold-reload contract (A1 review nit): an SMB server added at runtime must
    /// survive a fresh `ServerStore` over the SAME persisted defaults with its
    /// `shares` intact — i.e. `SMBServerData` round-trips through `UserDefaults`
    /// and the tolerant/strict decode keeps every share. Builds a SECOND store on
    /// the same `SettingsStore`+`FakeKeychain` and asserts the reload.
    @Test("SMB server reloads on a fresh store with its shares intact")
    func smbServerColdReloadKeepsShares() async throws {
        let suiteName = "ServerStoreMigrationTests-smb-reload-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        let keychain = FakeKeychain()

        // First store: add an SMB server with multiple shares.
        let writer = ServerStore(settings: settings, keychain: keychain)
        let id = try await writer.addSMBServer(
            SMBServerData(host: "nas", username: "alice", domain: "WORKGROUP", shares: ["Media", "TV"]),
            password: "pw"
        )

        // Second store on the SAME settings + keychain → cold reload.
        let reloaded = ServerStore(settings: settings, keychain: keychain)
        try await reloaded.load()

        let servers = await reloaded.servers
        #expect(servers.count == 1)
        guard let server = servers.first(where: { $0.id == id }),
              case .smb(let data) = server.kind else {
            Issue.record("expected the reloaded .smb server")
            return
        }
        #expect(data.host == "nas")
        #expect(data.username == "alice")
        #expect(data.domain == "WORKGROUP")
        #expect(data.shares == ["Media", "TV"])
    }

    /// A Keychain READ ERROR (locked device / missing entitlement) is NOT proof
    /// the token is gone, so the persisted record is RETAINED — only its
    /// session is skipped this launch. Locks the keep-on-error safety contract.
    @Test("Keychain read ERROR keeps the persisted server (only the session is skipped)")
    func keepsServerOnKeychainReadError() async throws {
        let suiteName = "ServerStoreMigrationTests-keep-\(UUID().uuidString)"
        let serverID = ServerID(rawValue: "srv-keep")
        let server = PersistedServer(
            id: serverID,
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://keep.test")!,
                serverName: "Keep Me",
                user: UserSnapshot(id: "u", name: "dave", serverLastUpdatedAt: nil)
            ))
        )
        do {
            let seeder = UserDefaults(suiteName: suiteName)!
            seeder.removePersistentDomain(forName: suiteName)
            seeder.set(try JSONEncoder().encode([server]), forKey: Self.persistedSessionsKeyName)
            seeder.synchronize()
        }

        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let keychain = FakeKeychain()
        // A non-notFound fault — exactly the -34018 class of error load() guards.
        keychain.setReadError(
            account: tokenKey(for: serverID).account,
            error: Keychain.KeychainError.unexpectedStatus(-34018)
        )
        let store = ServerStore(settings: settings, keychain: keychain)
        try await store.load()

        let servers = await store.servers
        let sessions = await store.sessions
        // Record RETAINED despite the read fault...
        #expect(servers.contains(where: { $0.id == serverID }))
        // ...but no session was built from it.
        #expect(sessions.isEmpty)

        // The persisted blob is untouched — the keep was not a silent prune.
        let reread = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingKey<[PersistedServer]>(name: Self.persistedSessionsKeyName, defaultValue: [])
        let persisted = try await reread.tryValue(for: key)
        #expect(persisted?.count == 1)
        #expect(persisted?.first?.id == serverID)
    }
}

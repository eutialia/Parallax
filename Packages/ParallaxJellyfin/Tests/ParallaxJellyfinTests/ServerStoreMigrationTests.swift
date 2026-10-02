import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
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

    /// Captures the real legacy wire bytes by round-tripping a live value
    /// through the same encoder `SettingsStore` uses — never hand-authored JSON.
    private func legacyWireBytes(_ sessions: [LegacyPersistedSession]) throws -> Data {
        try JSONEncoder().encode(sessions)
    }

    private func seedLegacy(_ data: Data, suiteName: String) {
        JellyfinFixtures.seedPersistedBytes(data, suiteName: suiteName)
    }

    private func tokenKey(for id: ServerID) -> KeychainKey<String> {
        JellyfinFixtures.tokenKey(for: id)
    }

    // MARK: - Pure persisted-shape migration

    /// THE high-risk assertion, both halves at once: an existing v1 user's stored blob must
    /// MIGRATE rather than throw `decodeFailed` (which crashes them to the login screen), the
    /// migrated row must resolve its bearer token so they stay signed in, and the upgraded shape
    /// must be written back so no second migration happens. Splitting these across two tests
    /// duplicated the identical seed just to assert a different side of one outcome.
    @Test("A legacy PersistedSession blob migrates in place, keeps the user signed in, and is written back")
    func migratesLegacyShape() async throws {
        let (settings, suiteName) = JellyfinFixtures.settingsStore("ServerStoreMigrationTests-shape")
        let serverID = ServerID(rawValue: "legacy-server-1")
        let legacy = LegacyPersistedSession(
            id: serverID,
            serverURL: URL(string: "https://example.test")!,
            serverName: "Living Room",
            user: UserSnapshot(id: "user-42", name: "alice", serverLastUpdatedAt: nil)
        )
        seedLegacy(try legacyWireBytes([legacy]), suiteName: suiteName)

        // Token present → the migrated server resolves and is kept.
        let keychain = FakeKeychain()
        try keychain.setValue("bearer-token-xyz", for: tokenKey(for: serverID))
        let store = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())

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

        // ...and the session rebuilt from the migrated row, so the user is still signed in.
        let sessions = await store.sessions
        #expect(sessions.count == 1)
        #expect(sessions.first?.accessToken == "bearer-token-xyz")
        #expect(await store.active?.id == serverID)

        // The upgraded shape was written back: the same key now re-reads cleanly as the NEW type,
        // so no second migration happens next launch.
        let upgraded = try await JellyfinFixtures.rereadPersistedServers(suiteName: suiteName)
        #expect(upgraded?.count == 1)
        if case .jellyfin(let j2)? = upgraded?.first?.kind {
            #expect(j2.serverURL.absoluteString == "https://example.test")
        } else {
            Issue.record("re-read upgraded value did not decode as .jellyfin")
        }
    }

    /// The v2 on-disk format and its storage key, pinned as hand-written JSON under the literal key
    /// (`JellyfinFixtures.persistedServersKeyName`) so a renamed `CodingKey`, enum envelope, or
    /// `SettingKey` fails here instead of logging every existing user out. The bytes must also
    /// survive `load()` untouched: no re-migration.
    @Test("A hand-written v2 blob under the literal key loads as-is and is not rewritten")
    func newShapeLoadsWithoutMigration() async throws {
        let (settings, suiteName) = JellyfinFixtures.settingsStore("ServerStoreMigrationTests-new")
        let jellyfinRow = #"{"id":"srv-new","kind":{"jellyfin":{"_0":{"serverURL":"https://already.migrated","serverName":"New","user":{"id":"u","name":"bob"}}}}}"#
        let smbRow = #"{"id":"smb-nas.local","kind":{"smb":{"_0":{"host":"nas.local","username":"alice","domain":"WORKGROUP","shares":["Media","TV"]}}}}"#
        let blob = Data("[\(jellyfinRow),\(smbRow)]".utf8)
        JellyfinFixtures.seedPersistedBytes(blob, suiteName: suiteName)

        let keychain = FakeKeychain()
        try keychain.setValue("tok", for: tokenKey(for: ServerID(rawValue: "srv-new")))
        let store = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())
        try await store.load()

        #expect(await store.servers == [
            PersistedServer(
                id: ServerID(rawValue: "srv-new"),
                kind: .jellyfin(JellyfinServerData(
                    serverURL: URL(string: "https://already.migrated")!,
                    serverName: "New",
                    user: UserSnapshot(id: "u", name: "bob", serverLastUpdatedAt: nil)
                ))
            ),
            PersistedServer(
                id: ServerID(rawValue: "smb-nas.local"),
                kind: .smb(SMBServerData(host: "nas.local", username: "alice", domain: "WORKGROUP", shares: ["Media", "TV"]))
            ),
        ])
        #expect(await store.sessions.map(\.accessToken) == ["tok"])
        #expect(JellyfinFixtures.rawPersistedBytes(suiteName: suiteName) == blob)
    }

    /// An older server's user blob still carries a `primaryImageTag` this app dropped. Decoding
    /// must tolerate the extra key rather than throw and take the whole server list down with it.
    @Test("UserSnapshot tolerates a dropped legacy field in stored JSON")
    func userSnapshotIgnoresLegacyProfileImageTag() throws {
        let json = """
        {"id":"user-1","name":"alice","primaryImageTag":"abc123","serverLastUpdatedAt":null}
        """
        let decoded = try JSONDecoder().decode(UserSnapshot.self, from: Data(json.utf8))
        #expect(decoded.name == "alice")
        #expect(decoded.id == "user-1")
    }

    // MARK: - load() token-resolution contracts

    /// A CONFIRMED-nil token read keeps the persisted Jellyfin server as signed-out —
    /// a real sign-out removes the row via `remove(_:)`, so a token-less row is always
    /// Keychain-side data loss (access-group change, device migration) and pruning it
    /// would destroy the user's server list over a recoverable fault.
    @Test("Confirmed-nil Keychain token keeps the persisted Jellyfin server as signed-out")
    func keepsServerOnConfirmedNilToken() async throws {
        let (settings, suiteName) = JellyfinFixtures.settingsStore("ServerStoreMigrationTests-prune")
        let serverID = ServerID(rawValue: "srv-prune")
        let server = PersistedServer(
            id: serverID,
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://prune.test")!,
                serverName: "Prune Me",
                user: UserSnapshot(id: "u", name: "carol", serverLastUpdatedAt: nil)
            ))
        )
        try JellyfinFixtures.seedPersistedServers([server], suiteName: suiteName)

        let keychain = FakeKeychain()
        keychain.setAbsent(account: tokenKey(for: serverID).account)
        let store = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())
        try await store.load()

        let servers = await store.servers
        let sessions = await store.sessions
        #expect(servers.contains(where: { $0.id == serverID }), "the row must survive a lost token")
        #expect(sessions.isEmpty)
        let signedOut = await store.signedOutJellyfinServers
        #expect(signedOut.map(\.id) == [serverID])

        // Nothing was written back — the persisted blob still holds the row.
        let persisted = try await JellyfinFixtures.rereadPersistedServers(suiteName: suiteName)
        #expect(persisted?.map(\.id) == [serverID])
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
        let (settings, suiteName) = JellyfinFixtures.settingsStore("ServerStoreMigrationTests-tolerant")
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
        // Swift's synthesized enum Codable wraps an associated value under "_0"; the
        // REAL on-disk shape for `.smb` is `{"smb":{"_0":{...}}}`. The element below
        // uses the correct envelope so the decoder reaches `SMBServerData` and fails
        // on the missing `shares` key (old pre-release fields `share`/`root`) — the
        // real-world drop path. Without `_0` the element would fail earlier (missing
        // `_0`) for the wrong reason, undermining the test's fidelity.
        let oldSMB = #"{"id":"smb-old","kind":{"smb":{"_0":{"host":"nas","share":"Media","root":"/Movies","username":"a","domain":"W"}}}}"#
        let json = "[\(validString),\(oldSMB)]"
        JellyfinFixtures.seedPersistedBytes(json.data(using: .utf8)!, suiteName: suiteName)

        let keychain = FakeKeychain()
        // Token present → the surviving Jellyfin server resolves and is kept.
        try keychain.setValue("bearer", for: tokenKey(for: jellyfinID))
        let store = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())

        // Must NOT throw — one bad element does not fail the array.
        try await store.load()

        let servers = await store.servers
        #expect(servers.count == 1)
        #expect(servers.first?.id == jellyfinID)
        #expect(servers.allSatisfy { if case .smb = $0.kind { return false }; return true })

        // The cleaned array was written back: the same key now re-reads as the
        // NEW type with the bad row already gone — no repeated salvage next launch.
        let persisted = try await JellyfinFixtures.rereadPersistedServers(suiteName: suiteName)
        #expect(persisted?.count == 1)
        #expect(persisted?.first?.id == jellyfinID)
    }

    /// Locks the retain-over-wipe safety guard: an array whose every element is
    /// undecodable — an old-shape SMB row (with the verified `{"smb":{"_0":{...}}}`
    /// envelope, so the decoder reaches `SMBServerData` and fails on missing `shares`)
    /// or an unrecognised shape — must NOT silently return `[]`. The tolerant pass
    /// yields zero survivors, which is indistinguishable from "bad blob that could
    /// still hold recoverable data", so
    /// `loadPersistedServers()` falls through to `decodeFailed` rather than
    /// persisting an empty array over the still-valid raw bytes. The raw blob must
    /// remain unchanged after the throw — no silent wipe.
    @Test(
        "all-incompatible array throws decodeFailed (retain-over-wipe) and leaves the blob intact",
        arguments: [
            #"[{"id":"smb-old","kind":{"smb":{"_0":{"host":"nas","share":"Media","root":"/Movies","username":"a","domain":"W"}}}}]"#,
            #"[{"unexpected":"shape"}]"#,
        ]
    )
    func allIncompatibleThrowsAndRetains(blob: String) async throws {
        let (settings, suiteName) = JellyfinFixtures.settingsStore("ServerStoreMigrationTests-retain")
        let seededBytes = Data(blob.utf8)
        JellyfinFixtures.seedPersistedBytes(seededBytes, suiteName: suiteName)

        let store = ServerStore(settings: settings, keychain: FakeKeychain(), snapshots: JellyfinFixtures.scratchSnapshots())

        // Must THROW — zero survivors must not silently return [] and wipe the blob.
        await #expect {
            try await store.load()
        } throws: { error in
            if case ServerStore.ServerStoreError.decodeFailed = error { true } else { false }
        }

        #expect(JellyfinFixtures.rawPersistedBytes(suiteName: suiteName) == seededBytes)
    }

    /// Cold-reload contract (A1 review nit): an SMB server added at runtime must
    /// survive a fresh `ServerStore` over the SAME persisted defaults with its
    /// `shares` intact — i.e. `SMBServerData` round-trips through `UserDefaults`
    /// and the tolerant/strict decode keeps every share. Builds a SECOND store on
    /// the same `SettingsStore`+`FakeKeychain` and asserts the reload.
    @Test("SMB server reloads on a fresh store with its shares intact")
    func smbServerColdReloadKeepsShares() async throws {
        let harness = JellyfinFixtures.serverStore("ServerStoreMigrationTests-smb-reload")

        // First store: add an SMB server with multiple shares.
        let id = try await harness.store.addSMBServer(
            JellyfinFixtures.smbData(host: "nas", shares: ["Media", "TV"]),
            password: "pw"
        )

        // Second store on the SAME settings + keychain → cold reload.
        let reloaded = ServerStore(settings: harness.settings, keychain: harness.keychain, snapshots: JellyfinFixtures.scratchSnapshots())
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
        let (settings, suiteName) = JellyfinFixtures.settingsStore("ServerStoreMigrationTests-keep")
        let serverID = ServerID(rawValue: "srv-keep")
        let server = PersistedServer(
            id: serverID,
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://keep.test")!,
                serverName: "Keep Me",
                user: UserSnapshot(id: "u", name: "dave", serverLastUpdatedAt: nil)
            ))
        )
        try JellyfinFixtures.seedPersistedServers([server], suiteName: suiteName)

        let keychain = FakeKeychain()
        // A non-notFound fault — exactly the -34018 class of error load() guards.
        keychain.setReadError(
            account: tokenKey(for: serverID).account,
            error: Keychain.KeychainError.unexpectedStatus(-34018)
        )
        let store = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())
        try await store.load()

        let servers = await store.servers
        let sessions = await store.sessions
        // Record RETAINED despite the read fault...
        #expect(servers.contains(where: { $0.id == serverID }))
        // ...but no session was built from it.
        #expect(sessions.isEmpty)

        // The persisted blob is untouched — the keep was not a silent prune.
        let persisted = try await JellyfinFixtures.rereadPersistedServers(suiteName: suiteName)
        #expect(persisted?.count == 1)
        #expect(persisted?.first?.id == serverID)
    }
}

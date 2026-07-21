import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

@Suite("ServerStore")
struct ServerStoreTests {
    private func freshStore() -> (ServerStore, FakeKeychain) {
        let suiteName = "ServerStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        let keychain = FakeKeychain()
        let store = ServerStore(settings: settings, keychain: keychain)
        return (store, keychain)
    }

    private func sampleSession(id: String = "server-1", token: String = "tok-1") -> Session {
        let data = JellyfinServerData(
            serverURL: URL(string: "https://j-\(id).example.com")!,
            serverName: "Server \(id)",
            user: UserSnapshot(id: "u-\(id)", name: "alice", serverLastUpdatedAt: nil)
        )
        return Session(id: ServerID(rawValue: id), data: data, accessToken: token)
    }

    @Test("Add session persists token and metadata, exposes it as the active session")
    func addStores() async throws {
        let (store, keychain) = freshStore()
        let session = sampleSession()

        try await store.add(session)
        try await store.load()

        let sessions = await store.sessions
        let active = await store.active
        #expect(sessions.count == 1)
        #expect(active?.id == session.id)
        #expect(active?.accessToken == "tok-1")

        let tokenKey = KeychainKey<String>(account: "token-\(session.id.rawValue)")
        let storedToken: String? = try await keychain.read(tokenKey)
        #expect(storedToken == "tok-1")
    }

    @Test("Load reconstructs sessions from UserDefaults + Keychain")
    func loadAfterRecreate() async throws {
        let suiteName = "ServerStoreTests-load-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        let keychain = FakeKeychain()

        let firstStore = ServerStore(settings: settings, keychain: keychain)
        try await firstStore.add(sampleSession(id: "s1", token: "t1"))
        try await firstStore.add(sampleSession(id: "s2", token: "t2"))
        try await firstStore.setActive(ServerID(rawValue: "s2"))

        // New store instance pointing at the same backing storage.
        let secondStore = ServerStore(settings: settings, keychain: keychain)
        try await secondStore.load()
        let sessions = await secondStore.sessions
        let active = await secondStore.active

        #expect(sessions.count == 2)
        #expect(active?.id == ServerID(rawValue: "s2"))
        #expect(active?.accessToken == "t2")
    }

    @Test("Remove deletes both Keychain token and UserDefaults metadata")
    func remove() async throws {
        let (store, keychain) = freshStore()
        let session = sampleSession()
        try await store.add(session)

        try await store.remove(session.id)

        let sessions = await store.sessions
        #expect(sessions.isEmpty)
        let tokenKey = KeychainKey<String>(account: "token-\(session.id.rawValue)")
        let storedToken: String? = try await keychain.read(tokenKey)
        #expect(storedToken == nil)
    }

    @Test("Load throws ServerStoreError.decodeFailed when persisted sessions cannot be decoded (refuses to wipe)")
    func loadRefusesToWipeOnDecodeFailure() async throws {
        let suiteName = "ServerStoreTests-decode-\(UUID().uuidString)"
        let corruptJSON = #"[{"unexpected":"shape"}]"#.data(using: .utf8)!
        let key = "ParallaxJellyfin.persistedSessions"

        // Seed the corrupt blob, then hand a fresh UserDefaults instance to
        // the actor — avoids sending a shared reference across isolation.
        do {
            let seeder = UserDefaults(suiteName: suiteName)!
            seeder.removePersistentDomain(forName: suiteName)
            seeder.set(corruptJSON, forKey: key)
            seeder.synchronize()
        }

        let store: ServerStore
        do {
            let defaults = UserDefaults(suiteName: suiteName)!
            let settings = SettingsStore(defaults: defaults)
            store = ServerStore(settings: settings, keychain: FakeKeychain())
        }

        await #expect(throws: ServerStore.ServerStoreError.self) {
            try await store.load()
        }

        // Crucially: the raw UserDefaults data is still there — refusing to
        // load means refusing to overwrite. The orphan-cleanup branch of
        // load() must NOT have fired.
        let verifier = UserDefaults(suiteName: suiteName)!
        let stillThere = verifier.data(forKey: key)
        #expect(stillThere == corruptJSON)
    }

    @Test("Load keeps a Jellyfin server whose token vanished, exposing it as signed-out")
    func loadKeepsMissingTokenServerAsSignedOut() async throws {
        let (store, keychain) = freshStore()
        try await store.add(sampleSession(id: "ghost", token: "tok"))

        // Simulate the token disappearing underneath us (access-group change after a
        // bundle-id rename, device migration with ThisDeviceOnly items, Keychain reset).
        // A real sign-out goes through remove(_:), which deletes the ROW too — so a
        // token-less row is always Keychain-side data loss, never a completed sign-out,
        // and pruning it would destroy the user's server list over a recoverable fault.
        let tokenKey = KeychainKey<String>(account: "token-ghost")
        try await keychain.delete(tokenKey)

        try await store.load()

        #expect(await store.sessions.isEmpty)
        let servers = await store.servers
        #expect(servers.map(\.id) == [ServerID(rawValue: "ghost")], "the persisted row must survive")
        let signedOut = await store.signedOutJellyfinServers
        #expect(signedOut.map(\.id) == [ServerID(rawValue: "ghost")], "and be surfaced as signed-out")
    }

    @Test("Re-adding the same server heals its signed-out row")
    func reAddHealsSignedOutRow() async throws {
        let (store, keychain) = freshStore()
        try await store.add(sampleSession(id: "ghost", token: "tok"))
        try await keychain.delete(KeychainKey<String>(account: "token-ghost"))
        try await store.load()

        // Signing in again yields the same deterministic server id → add() replaces in place.
        try await store.add(sampleSession(id: "ghost", token: "tok-new"))

        #expect(await store.signedOutJellyfinServers.isEmpty)
        #expect(await store.sessions.count == 1)
        #expect(await store.servers.count == 1)
    }

    // MARK: - smbPassword

    @Test("smbPassword returns the stored password, including a stored-empty guest password")
    func smbPasswordReadsStored() async throws {
        let (store, _) = freshStore()
        let data = SMBServerData(host: "nas", username: "", domain: "", shares: [])
        let id = try await store.addSMBServer(data, password: "")
        // addSMBServer always stores the password — even a guest's empty one — so a
        // stored-empty read must come back as "", NOT be confused with a lost slot.
        #expect(try await store.smbPassword(for: id) == "")
    }

    @Test("smbPassword throws credentialUnavailable when the slot is lost")
    func smbPasswordThrowsOnLostSlot() async throws {
        let (store, keychain) = freshStore()
        let data = SMBServerData(host: "nas", username: "alice", domain: "", shares: [])
        let id = try await store.addSMBServer(data, password: "secret")
        try await keychain.delete(KeychainKey<String>(account: "token-\(id.rawValue)"))

        do {
            _ = try await store.smbPassword(for: id)
            Issue.record("a lost slot must throw, not degrade to a guest logon")
        } catch let error as AppError {
            guard case .auth(.credentialUnavailable) = error else {
                Issue.record("expected .auth(.credentialUnavailable), got \(error)")
                return
            }
        }
    }
}

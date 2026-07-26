import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

@Suite("ServerStore")
struct ServerStoreTests {
    @Test("Add session persists token and metadata, exposes it as the active session")
    func addStores() async throws {
        let harness = JellyfinFixtures.serverStore()
        let session = JellyfinFixtures.session(id: "server-1", token: "tok-1")

        try await harness.store.add(session)
        try await harness.store.load()

        #expect(await harness.store.sessions.count == 1)
        #expect(await harness.store.active?.id == session.id)
        #expect(await harness.store.active?.accessToken == "tok-1")

        let storedToken: String? = try await harness.keychain.read(JellyfinFixtures.tokenKey(for: session.id))
        #expect(storedToken == "tok-1")
    }

    @Test("Load reconstructs sessions from UserDefaults + Keychain")
    func loadAfterRecreate() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "s1", token: "t1"))
        try await harness.store.add(JellyfinFixtures.session(id: "s2", token: "t2"))
        try await harness.store.setActive(ServerID(rawValue: "s2"))

        // A new store instance pointing at the same backing storage — i.e. the next launch.
        let relaunched = ServerStore(settings: harness.settings, keychain: harness.keychain)
        try await relaunched.load()

        #expect(await relaunched.sessions.count == 2)
        #expect(await relaunched.active?.id == ServerID(rawValue: "s2"))
        #expect(await relaunched.active?.accessToken == "t2")
    }

    /// The stored active id has to be validated on load: if that server is gone (removed on
    /// another launch, or signed out), the store must fall back to a live session rather than
    /// reporting no active server while sessions exist.
    @Test("A stale persisted active id falls back to a surviving session and is rewritten")
    func staleActiveIDFallsBack() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "s1", token: "t1"))
        try await harness.store.add(JellyfinFixtures.session(id: "s2", token: "t2"))
        try await harness.store.setActive(ServerID(rawValue: "s2"))
        // s2's token vanishes, so it can't rebuild a session on the next load.
        try await harness.keychain.delete(JellyfinFixtures.tokenKey(forRawID: "s2"))

        let relaunched = ServerStore(settings: harness.settings, keychain: harness.keychain)
        try await relaunched.load()

        #expect(await relaunched.active?.id == ServerID(rawValue: "s1"))

        // The corrected id was written back, so the fallback isn't re-derived every launch.
        let again = ServerStore(settings: harness.settings, keychain: harness.keychain)
        try await again.load()
        #expect(await again.active?.id == ServerID(rawValue: "s1"))
    }

    @Test("setActive ignores a server with no live session")
    func setActiveIgnoresUnknownServer() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "s1", token: "t1"))

        try await harness.store.setActive(ServerID(rawValue: "not-a-server"))

        #expect(await harness.store.active?.id == ServerID(rawValue: "s1"))
    }

    @Test("Remove deletes both Keychain token and UserDefaults metadata")
    func remove() async throws {
        let harness = JellyfinFixtures.serverStore()
        let session = JellyfinFixtures.session(id: "server-1")
        try await harness.store.add(session)

        try await harness.store.remove(session.id)

        #expect(await harness.store.sessions.isEmpty)
        let storedToken: String? = try await harness.keychain.read(JellyfinFixtures.tokenKey(for: session.id))
        #expect(storedToken == nil)
    }

    /// Removing the ACTIVE server has to hand active status to a survivor; leaving it dangling
    /// would nil-route the Jellyfin-keyed router to the login screen with servers still configured.
    @Test("Removing the active server promotes a survivor")
    func removeActivePromotesSurvivor() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "s1", token: "t1"))
        try await harness.store.add(JellyfinFixtures.session(id: "s2", token: "t2"))
        try await harness.store.setActive(ServerID(rawValue: "s1"))

        try await harness.store.remove(ServerID(rawValue: "s1"))

        #expect(await harness.store.active?.id == ServerID(rawValue: "s2"))
    }

    @Test("Load throws ServerStoreError.decodeFailed when persisted sessions cannot be decoded (refuses to wipe)")
    func loadRefusesToWipeOnDecodeFailure() async throws {
        let (settings, suiteName) = JellyfinFixtures.settingsStore("ServerStoreTests-decode")
        let corruptJSON = #"[{"unexpected":"shape"}]"#.data(using: .utf8)!
        JellyfinFixtures.seedPersistedBytes(corruptJSON, suiteName: suiteName)
        let store = ServerStore(settings: settings, keychain: FakeKeychain())

        await #expect(throws: ServerStore.ServerStoreError.self) {
            try await store.load()
        }

        // Crucially: the raw bytes are still there — refusing to load means refusing to overwrite.
        #expect(JellyfinFixtures.rawPersistedBytes(suiteName: suiteName) == corruptJSON)
    }

    @Test("Load keeps a Jellyfin server whose token vanished, exposing it as signed-out")
    func loadKeepsMissingTokenServerAsSignedOut() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "ghost", token: "tok"))

        // Simulate the token disappearing underneath us (access-group change after a bundle-id
        // rename, device migration with ThisDeviceOnly items, Keychain reset). A real sign-out goes
        // through remove(_:), which deletes the ROW too — so a token-less row is always
        // Keychain-side data loss, never a completed sign-out, and pruning it would destroy the
        // user's server list over a recoverable fault.
        try await harness.keychain.delete(JellyfinFixtures.tokenKey(forRawID: "ghost"))

        try await harness.store.load()

        #expect(await harness.store.sessions.isEmpty)
        #expect(await harness.store.servers.map(\.id) == [ServerID(rawValue: "ghost")], "the persisted row must survive")
        #expect(
            await harness.store.signedOutJellyfinServers.map(\.id) == [ServerID(rawValue: "ghost")],
            "and be surfaced as signed-out"
        )
    }

    @Test("Re-adding the same server heals its signed-out row")
    func reAddHealsSignedOutRow() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "ghost", token: "tok"))
        try await harness.keychain.delete(JellyfinFixtures.tokenKey(forRawID: "ghost"))
        try await harness.store.load()

        // Signing in again yields the same deterministic server id → add() replaces in place.
        try await harness.store.add(JellyfinFixtures.session(id: "ghost", token: "tok-new"))

        #expect(await harness.store.signedOutJellyfinServers.isEmpty)
        #expect(await harness.store.sessions.count == 1)
        #expect(await harness.store.servers.count == 1)
        #expect(await harness.store.sessions.first?.accessToken == "tok-new")
    }

    // MARK: - Hidden library collections

    /// Per-server visibility, keyed by server: the same collection id on two servers must not
    /// hide both, which is why the map is keyed rather than a flat set.
    @Test("Hidden collections are stored per server and survive a relaunch")
    func hiddenCollectionsRoundTrip() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "s1", token: "t1"))
        try await harness.store.add(JellyfinFixtures.session(id: "s2", token: "t2"))

        try await harness.store.setHiddenCollectionIDs(["coll-a", "coll-b"], for: ServerID(rawValue: "s1"))

        #expect(await harness.store.hiddenCollectionIDs(for: ServerID(rawValue: "s1")) == ["coll-a", "coll-b"])
        #expect(await harness.store.hiddenCollectionIDs(for: ServerID(rawValue: "s2")).isEmpty)
        #expect(await harness.store.allHiddenCollectionIDs == [ServerID(rawValue: "s1"): ["coll-a", "coll-b"]])

        let relaunched = ServerStore(settings: harness.settings, keychain: harness.keychain)
        try await relaunched.load()
        #expect(await relaunched.hiddenCollectionIDs(for: ServerID(rawValue: "s1")) == ["coll-a", "coll-b"])
    }

    @Test("Re-showing every library drops the server's entry entirely")
    func hiddenCollectionsClearDropsEntry() async throws {
        let harness = JellyfinFixtures.serverStore()
        try await harness.store.add(JellyfinFixtures.session(id: "s1", token: "t1"))
        try await harness.store.setHiddenCollectionIDs(["coll-a"], for: ServerID(rawValue: "s1"))

        try await harness.store.setHiddenCollectionIDs([], for: ServerID(rawValue: "s1"))

        #expect(await harness.store.allHiddenCollectionIDs.isEmpty)
    }

    /// A Jellyfin re-add reuses the deterministic server id, so a lingering visibility set would
    /// silently hide libraries on a freshly added server.
    @Test("Removing a server purges its hidden-collections set")
    func removePurgesHiddenCollections() async throws {
        let harness = JellyfinFixtures.serverStore()
        let session = JellyfinFixtures.session(id: "s1", token: "t1")
        try await harness.store.add(session)
        try await harness.store.setHiddenCollectionIDs(["coll-a"], for: session.id)

        try await harness.store.remove(session.id)
        try await harness.store.add(session)

        #expect(await harness.store.hiddenCollectionIDs(for: session.id).isEmpty)
        let relaunched = ServerStore(settings: harness.settings, keychain: harness.keychain)
        try await relaunched.load()
        #expect(await relaunched.allHiddenCollectionIDs.isEmpty)
    }

    // MARK: - smbPassword

    @Test("smbPassword returns the stored password, including a stored-empty guest password")
    func smbPasswordReadsStored() async throws {
        let harness = JellyfinFixtures.serverStore()
        let id = try await harness.store.addSMBServer(
            JellyfinFixtures.smbData(host: "nas", username: "", domain: "", shares: []),
            password: ""
        )
        // addSMBServer always stores the password — even a guest's empty one — so a stored-empty
        // read must come back as "", NOT be confused with a lost slot.
        #expect(try await harness.store.smbPassword(for: id) == "")
    }

    @Test("smbPassword throws credentialUnavailable when the slot is lost")
    func smbPasswordThrowsOnLostSlot() async throws {
        let harness = JellyfinFixtures.serverStore()
        let id = try await harness.store.addSMBServer(JellyfinFixtures.smbData(host: "nas"), password: "secret")
        try await harness.keychain.delete(JellyfinFixtures.tokenKey(for: id))

        // A lost slot must throw, not degrade to a guest logon the server rejects with an error
        // that reads as its own fault.
        do {
            _ = try await harness.store.smbPassword(for: id)
            Issue.record("a lost slot must throw, not degrade to a guest logon")
        } catch let error as AppError {
            guard case .auth(.credentialUnavailable) = error else {
                Issue.record("expected .auth(.credentialUnavailable), got \(error)")
                return
            }
        }
    }

    /// A Keychain READ FAULT is not the same as a missing slot: the credential may be perfectly
    /// fine behind a locked device, so it surfaces as an unexpected failure rather than as
    /// "re-enter your password".
    @Test("A Keychain read fault surfaces as unexpected, not as a missing credential")
    func smbPasswordReadFault() async throws {
        let harness = JellyfinFixtures.serverStore()
        let id = try await harness.store.addSMBServer(JellyfinFixtures.smbData(host: "nas"), password: "secret")
        harness.keychain.setReadError(
            account: ServerStore.tokenAccount(for: id),
            error: Keychain.KeychainError.unexpectedStatus(-25308)
        )

        do {
            _ = try await harness.store.smbPassword(for: id)
            Issue.record("a read fault must throw")
        } catch let error as AppError {
            guard case .unexpected = error else {
                Issue.record("expected .unexpected, got \(error)")
                return
            }
        }
    }
}

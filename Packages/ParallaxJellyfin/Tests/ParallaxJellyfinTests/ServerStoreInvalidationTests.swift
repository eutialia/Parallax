import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

/// `invalidateSession(_:)` — the runtime path for a token the SERVER rejected (HTTP 401), as
/// opposed to `remove(_:)`, which is a deliberate sign-out. The distinction is the whole point:
/// the user still wants this server, so its row must survive as signed-out and be re-signable.
@Suite("ServerStore token invalidation")
struct ServerStoreInvalidationTests {
    private func freshStore() -> (ServerStore, FakeKeychain, SettingsStore) {
        let harness = JellyfinFixtures.serverStore("ServerStoreInvalidationTests")
        return (harness.store, harness.keychain, harness.settings)
    }

    private func session(id: String, token: String) -> Session {
        JellyfinFixtures.session(id: id, token: token)
    }

    @Test("A rejected token drops the session but keeps the row, so the server reads as signed-out")
    func invalidationKeepsRow() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "dead"))

        let changed = await store.invalidateSession(ServerID(rawValue: "s1"))

        #expect(changed)
        #expect(await store.sessions.isEmpty)
        // The row survives — this is NOT `remove(_:)`. Losing it would silently delete a server
        // the user never asked to remove, with no trace that it was ever configured.
        #expect(await store.servers.count == 1)
        #expect(await store.signedOutJellyfinServers.map(\.id) == [ServerID(rawValue: "s1")])
    }

    /// The dead token must not survive to the next launch: `load()` would rebuild a session from
    /// it, the server would look connected again, and every request would 401 — reproducing
    /// exactly the silent-empty state this fix exists to end.
    @Test("The rejected token is deleted, so a relaunch doesn't resurrect the dead session")
    func invalidationDeletesToken() async throws {
        let (store, keychain, settings) = freshStore()
        try await store.add(session(id: "s1", token: "dead"))

        await store.invalidateSession(ServerID(rawValue: "s1"))

        let stored: String? = try await keychain.read(JellyfinFixtures.tokenKey(forRawID: "s1"))
        #expect(stored == nil)

        let relaunched = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())
        try await relaunched.load()
        #expect(await relaunched.sessions.isEmpty)
        #expect(await relaunched.signedOutJellyfinServers.count == 1)
    }

    /// Concurrent requests all 401 together, so the handler is called several times for one dead
    /// token. Only the first call may report a change — the caller uses the result to skip a
    /// redundant router re-route per in-flight request.
    @Test("Re-invalidating an already signed-out server reports no change")
    func repeatInvalidationIsIdempotent() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "dead"))

        let unknown = await store.invalidateSession(ServerID(rawValue: "nope"))
        #expect(unknown == false)
        #expect(await store.sessions.count == 1)

        let first = await store.invalidateSession(ServerID(rawValue: "s1"))
        let second = await store.invalidateSession(ServerID(rawValue: "s1"))

        #expect(first)
        #expect(second == false)
    }

    @Test("Invalidating one of two servers signs out only that one and hands active status to the survivor")
    func activeMovesToASurvivor() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "t1"))
        try await store.add(session(id: "s2", token: "t2"))

        await store.invalidateSession(ServerID(rawValue: "s1"))

        #expect(await store.active?.id == ServerID(rawValue: "s2"))
        #expect(await store.sessions.map(\.id) == [ServerID(rawValue: "s2")])
        #expect(await store.servers.count == 2)
    }
}

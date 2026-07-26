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

        let relaunched = ServerStore(settings: settings, keychain: keychain)
        try await relaunched.load()
        #expect(await relaunched.sessions.isEmpty)
        #expect(await relaunched.signedOutJellyfinServers.count == 1)
    }

    @Test("Only the rejected server is signed out; the others keep their sessions")
    func invalidationIsPerServer() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "t1"))
        try await store.add(session(id: "s2", token: "t2"))

        await store.invalidateSession(ServerID(rawValue: "s2"))

        #expect(await store.sessions.map(\.id) == [ServerID(rawValue: "s1")])
        #expect(await store.servers.count == 2)
    }

    /// Concurrent requests all 401 together, so the handler is called several times for one dead
    /// token. Only the first call may report a change — the caller uses the result to skip a
    /// redundant router re-route per in-flight request.
    @Test("Re-invalidating an already signed-out server reports no change")
    func repeatInvalidationIsIdempotent() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "dead"))

        let first = await store.invalidateSession(ServerID(rawValue: "s1"))
        let second = await store.invalidateSession(ServerID(rawValue: "s1"))

        #expect(first)
        #expect(second == false)
    }

    @Test("Invalidating the active server hands active status to a surviving one")
    func activeMovesToASurvivor() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "t1"))
        try await store.add(session(id: "s2", token: "t2"))
        try await store.setActive(ServerID(rawValue: "s1"))

        await store.invalidateSession(ServerID(rawValue: "s1"))

        #expect(await store.active?.id == ServerID(rawValue: "s2"))
    }

    /// The roots key their reload `.task` on this snapshot, so an invalidation that didn't move it
    /// would leave the dead server's libraries on screen until something else happened to change.
    @Test("Invalidation moves the source snapshot, re-firing the navigation roots")
    func invalidationMovesTheSourceSnapshot() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "t1"))
        try await store.add(session(id: "s2", token: "t2"))
        let before = await store.sourceSnapshot

        await store.invalidateSession(ServerID(rawValue: "s2"))
        let after = await store.sourceSnapshot

        #expect(before.setIdentity != after.setIdentity)
        // The row is still there, just no longer live — the identity records both facts. Its exact
        // composition is pinned once, in ServerStoreSourceSnapshotTests; here the point is that the
        // invalidated id survives in the identity while its live marker moves.
        #expect(await store.servers.map(\.id).contains(ServerID(rawValue: "s2")))
        #expect(before.setIdentity.split(separator: ",").count == after.setIdentity.split(separator: ",").count)
    }

    @Test("Invalidating an unknown or already-removed server is a no-op")
    func unknownServerIsANoOp() async throws {
        let (store, _, _) = freshStore()
        try await store.add(session(id: "s1", token: "t1"))

        let changed = await store.invalidateSession(ServerID(rawValue: "nope"))

        #expect(changed == false)
        #expect(await store.sessions.count == 1)
    }
}

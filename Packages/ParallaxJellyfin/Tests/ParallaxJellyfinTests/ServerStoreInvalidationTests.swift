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
        let dead = session(id: "s1", token: "dead")
        try await store.add(dead)

        let changed = await store.invalidateSession(dead)

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
        let dead = session(id: "s1", token: "dead")
        try await store.add(dead)

        await store.invalidateSession(dead)

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
        let dead = session(id: "s1", token: "dead")
        try await store.add(dead)

        let unknown = await store.invalidateSession(session(id: "nope", token: "dead"))
        #expect(unknown == false)
        #expect(await store.sessions.count == 1)

        let first = await store.invalidateSession(dead)
        let second = await store.invalidateSession(dead)

        #expect(first)
        #expect(second == false)
    }

    @Test("Invalidating one of two servers signs out only that one and hands active status to the survivor")
    func activeMovesToASurvivor() async throws {
        let (store, _, _) = freshStore()
        let first = session(id: "s1", token: "t1")
        try await store.add(first)
        try await store.add(session(id: "s2", token: "t2"))

        await store.invalidateSession(first)

        #expect(await store.active?.id == ServerID(rawValue: "s2"))
        #expect(await store.sessions.map(\.id) == [ServerID(rawValue: "s2")])
        #expect(await store.servers.count == 2)
    }

    /// A rejection names the token a request carried. Signing the server in again replaces that
    /// token, and a 401 still in flight for the old one must not sign the new one out.
    @Test("A rejection of a replaced token leaves the session that replaced it alone")
    func staleRejectionKeepsTheNewSession() async throws {
        let (store, keychain, _) = freshStore()
        let replaced = session(id: "s1", token: "old")
        try await store.add(replaced)
        let current = session(id: "s1", token: "new")
        try await store.add(current)

        let changed = await store.invalidateSession(replaced)

        #expect(changed == false)
        #expect(await store.sessions == [current])
        let stored: String? = try await keychain.read(JellyfinFixtures.tokenKey(forRawID: "s1"))
        #expect(stored == "new")
    }

    /// A 401 for the old token can land while a re-sign-in of the same server is suspended in its
    /// Keychain write. The re-sign-in must not land on whatever row now sits where its server was.
    @Test("A rejection landing mid re-sign-in keeps every other server's session")
    func rejectionDuringReSignInKeepsNeighbours() async throws {
        let (settings, _) = JellyfinFixtures.settingsStore("ServerStoreInvalidationTests")
        let keychain = HeldStoreKeychain()
        let store = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())
        let old = session(id: "s1", token: "old")
        let neighbour = session(id: "s2", token: "t2")
        let renewed = session(id: "s1", token: "new")
        try await store.add(old)
        try await store.add(neighbour)
        await keychain.holdNextStore()

        async let reSignIn: Void = store.add(renewed)
        await keychain.waitUntilHeld()
        await store.invalidateSession(old)
        await keychain.release()
        try await reSignIn

        let tokens = await store.sessions.map(\.accessToken)
        #expect(tokens == [neighbour.accessToken, renewed.accessToken])
    }

    /// The mirror order: the rejection is suspended in its Keychain delete when the user signs the
    /// server in again. The delete must not land on the token that sign-in just stored.
    @Test("A re-sign-in during a rejection's Keychain delete keeps its new token")
    func reSignInDuringRejectionKeepsTheNewToken() async throws {
        let (settings, _) = JellyfinFixtures.settingsStore("ServerStoreInvalidationTests")
        let keychain = HeldStoreKeychain()
        let store = ServerStore(settings: settings, keychain: keychain, snapshots: JellyfinFixtures.scratchSnapshots())
        let old = session(id: "s1", token: "old")
        let renewed = session(id: "s1", token: "new")
        try await store.add(old)
        await keychain.holdNextDelete()

        let rejection = Task { await store.invalidateSession(old) }
        await keychain.waitUntilHeld()
        let reSignIn = Task { try await store.add(renewed) }
        // The sign-in gets every chance to reach the Keychain ahead of the parked delete.
        for _ in 0..<200 where await keychain.storeCount < 2 { await Task.yield() }
        await keychain.release()
        _ = await rejection.value
        try await reSignIn.value

        let stored: String? = try await keychain.read(JellyfinFixtures.tokenKey(forRawID: "s1"))
        #expect(stored == "new")
        #expect(await store.sessions == [renewed])
        #expect(await store.active == renewed)
    }
}

/// Parks the next `store` or `delete` until released, so a test can run other actor work inside
/// that await.
private actor HeldStoreKeychain: KeychainStoring {
    enum Operation { case store, delete }

    private enum Hold {
        case none
        case armed(Operation)
        case parked(CheckedContinuation<Void, Never>)
    }

    private let backing = FakeKeychain()
    private var hold = Hold.none
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var storeCount = 0

    func holdNextStore() { hold = .armed(.store) }
    func holdNextDelete() { hold = .armed(.delete) }

    func waitUntilHeld() async {
        if case .parked = hold { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        if case .parked(let continuation) = hold { continuation.resume() }
        hold = .none
    }

    private func park(_ operation: Operation) async {
        guard case .armed(operation) = hold else { return }
        await withCheckedContinuation { continuation in
            hold = .parked(continuation)
            heldWaiters.forEach { $0.resume() }
            heldWaiters = []
        }
    }

    func store<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) async throws {
        await park(.store)
        try await backing.store(value, for: key)
        storeCount += 1
    }

    func read<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws -> Value? {
        try await backing.read(key)
    }

    func delete<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws {
        await park(.delete)
        try await backing.delete(key)
    }
}

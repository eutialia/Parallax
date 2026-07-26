import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

/// `sourceSnapshot` is the one read the app's router is driven by, and `setIdentity` is what makes a
/// change to the SET of configured sources visible to the navigation roots. These cover the cases
/// the router's previous input ("active session + an SMB Bool") was structurally blind to — the
/// device bug where a newly added second Jellyfin server didn't appear in the sidebar until relaunch.
@Suite("ServerStore source snapshot")
struct ServerStoreSourceSnapshotTests {
    private func freshStore() -> ServerStore {
        JellyfinFixtures.serverStore("ServerStoreSourceSnapshotTests").store
    }

    private func session(_ id: String) -> Session {
        JellyfinFixtures.session(id: id, token: "tok-\(id)")
    }

    @Test("An empty store reports the empty identity, distinguishable from any configured set")
    func emptyStore() async {
        let store = freshStore()
        let snapshot = await store.sourceSnapshot

        #expect(snapshot.setIdentity.isEmpty)
        #expect(snapshot.activeSessionID == nil)
        #expect(snapshot.hasAuxiliarySources == false)
        #expect(snapshot.hasAnySource == false)
    }

    /// The anchor for every inequality assertion below: without ONE test pinning the composition,
    /// a degenerate implementation (a fresh UUID per mutation) would satisfy all of them.
    @Test("setIdentity composes id + live marker per row, in persisted order")
    func identityComposition() async throws {
        let store = freshStore()
        try await store.add(session("alpha"))
        _ = try await store.addSMBServer(
            JellyfinFixtures.smbData(host: "nas.local", shares: ["Media"]),
            password: "pw"
        )
        try await store.add(session("beta"))

        // A live Jellyfin row is `id+`; a row with no live session is `id-`, which is what an SMB
        // server always is (it has no Session at all).
        #expect(await store.sourceSnapshot.setIdentity == "alpha+,smb-nas.local-,beta+")
    }

    @Test("Adding a SECOND Jellyfin server changes setIdentity while the active session stays put")
    func secondJellyfinServerChangesIdentity() async throws {
        let store = freshStore()
        try await store.add(session("alpha"))
        let afterFirst = await store.sourceSnapshot

        try await store.add(session("beta"))
        let afterSecond = await store.sourceSnapshot

        // The whole point: the active server is UNCHANGED (add only claims `active` when it's nil),
        // so nothing but the identity can tell the roots to rebuild.
        #expect(afterSecond.activeSessionID == afterFirst.activeSessionID)
        #expect(afterSecond.activeSessionID == ServerID(rawValue: "alpha"))
        #expect(afterSecond.hasAuxiliarySources == afterFirst.hasAuxiliarySources)
        #expect(afterSecond.setIdentity != afterFirst.setIdentity)
    }

    @Test("Removing a NON-active Jellyfin server changes setIdentity, active session unchanged")
    func removingNonActiveServerChangesIdentity() async throws {
        let store = freshStore()
        try await store.add(session("alpha"))
        try await store.add(session("beta"))
        let both = await store.sourceSnapshot

        try await store.remove(ServerID(rawValue: "beta"))
        let one = await store.sourceSnapshot

        #expect(one.activeSessionID == both.activeSessionID)
        #expect(one.setIdentity != both.setIdentity)
    }

    @Test("Identity marks live vs signed-out rows, so re-signing in is a visible change")
    func liveMarkerDistinguishesSignedOutRows() async throws {
        // A row whose Keychain token is unreadable rebuilds as signed-out on load: same persisted
        // id, but it contributes no libraries, so the roots must rebuild when it heals.
        let harness = JellyfinFixtures.serverStore("ServerStoreSourceSnapshotTests-heal")
        let keychain = harness.keychain
        let settings = harness.settings

        let seeding = harness.store
        try await seeding.add(session("alpha"))
        try await seeding.add(session("beta"))

        // Drop beta's token, then reload: its row survives as signed-out.
        try await keychain.delete(JellyfinFixtures.tokenKey(forRawID: "beta"))
        let reloaded = ServerStore(settings: settings, keychain: keychain)
        try await reloaded.load()

        let withSignedOutRow = await reloaded.sourceSnapshot
        #expect(await reloaded.signedOutJellyfinServers.count == 1)

        // Re-signing in heals the row in place — the id list is identical, only the live marker moves.
        try await reloaded.add(session("beta"))
        let healed = await reloaded.sourceSnapshot

        #expect(healed.setIdentity != withSignedOutRow.setIdentity)
    }

    @Test("Identity is order-sensitive so it tracks the add order the sidebar renders")
    func identityFollowsPersistedOrder() async throws {
        let first = freshStore()
        try await first.add(session("alpha"))
        try await first.add(session("beta"))

        let second = freshStore()
        try await second.add(session("beta"))
        try await second.add(session("alpha"))

        let firstIdentity = await first.sourceSnapshot.setIdentity
        let secondIdentity = await second.sourceSnapshot.setIdentity
        #expect(firstIdentity != secondIdentity)
    }

    @Test("An SMB server sets hasAuxiliarySources and lands in the identity")
    func smbServerInSnapshot() async throws {
        let store = freshStore()
        _ = try await store.addSMBServer(
            SMBServerData(host: "nas.local", username: "alice", domain: "", shares: ["Media"]),
            password: "pw"
        )
        let snapshot = await store.sourceSnapshot

        #expect(snapshot.hasAuxiliarySources)
        // No Jellyfin session, but a real browsable source — the SMB-only home case.
        #expect(snapshot.activeSessionID == nil)
        #expect(snapshot.hasAnySource)
        #expect(snapshot.setIdentity.contains("smb-nas.local"))
    }
}

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
        let suiteName = "ServerStoreSourceSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ServerStore(settings: SettingsStore(defaults: defaults), keychain: FakeKeychain())
    }

    private func session(_ id: String) -> Session {
        Session(
            id: ServerID(rawValue: id),
            data: JellyfinServerData(
                serverURL: URL(string: "https://\(id).example.com")!,
                serverName: "Server \(id)",
                user: UserSnapshot(id: "u-\(id)", name: "alice", serverLastUpdatedAt: nil)
            ),
            accessToken: "tok-\(id)"
        )
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
        let suiteName = "ServerStoreSourceSnapshotTests-heal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = FakeKeychain()
        let settings = SettingsStore(defaults: defaults)

        let seeding = ServerStore(settings: settings, keychain: keychain)
        try await seeding.add(session("alpha"))
        try await seeding.add(session("beta"))

        // Drop beta's token, then reload: its row survives as signed-out.
        try await keychain.delete(KeychainKey<String>(account: ServerStore.tokenAccount(for: ServerID(rawValue: "beta"))))
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

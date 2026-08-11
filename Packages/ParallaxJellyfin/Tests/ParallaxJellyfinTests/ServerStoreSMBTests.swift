import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

@Suite("ServerStore SMB write path")
struct ServerStoreSMBTests {
    // MARK: - Helpers

    private func freshStore() -> (ServerStore, SettingsStore, FakeKeychain) {
        let harness = JellyfinFixtures.serverStore("ServerStoreSMBTests")
        return (harness.store, harness.settings, harness.keychain)
    }

    private func smbData(host: String = "nas.local", shares: [String] = ["Media", "Backups"]) -> SMBServerData {
        JellyfinFixtures.smbData(host: host, shares: shares)
    }

    private func sampleSession(id: String = "jf-1", token: String = "tok-jf") -> Session {
        JellyfinFixtures.session(id: id, token: token)
    }

    private func tokenKey(for id: ServerID) -> KeychainKey<String> {
        JellyfinFixtures.tokenKey(for: id)
    }

    /// Readable kind predicate — the alternative (an immediately-applied closure inside
    /// `contains {}`) obscured what was being asserted.
    private func isJellyfin(_ server: PersistedServer) -> Bool {
        if case .jellyfin = server.kind { return true }
        return false
    }

    // MARK: - Tests

    @Test("addSMBServer persists .smb PersistedServer, stores password in Keychain, does not touch sessions or active")
    func addPersistsServerAndPassword() async throws {
        let (store, _, keychain) = freshStore()
        let data = smbData()

        let id = try await store.addSMBServer(data, password: "s3cr3t")

        // ID scheme: "smb-<host>" — deterministic so a re-add heals the row in place instead of
        // duplicating it, and prefixed so it can never collide with a Jellyfin server id.
        #expect(id.rawValue == "smb-nas.local")

        let servers = await store.servers
        #expect(servers.count == 1)
        guard let server = servers.first, case .smb(let stored) = server.kind else {
            Issue.record("expected one .smb PersistedServer")
            return
        }
        #expect(server.id == id)
        #expect(stored.host == "nas.local")
        #expect(stored.shares == ["Media", "Backups"])
        #expect(stored.username == "alice")

        // Password stored under token-<id>
        let storedPassword: String? = try await keychain.read(tokenKey(for: id))
        #expect(storedPassword == "s3cr3t")

        // No sessions — SMB has no Session
        let sessions = await store.sessions
        #expect(sessions.isEmpty)

        // active is nil (no Jellyfin session)
        let active = await store.active
        #expect(active == nil)
    }

    @Test("Re-adding the same host reuses the same id, updates shares, and updates the stored password")
    func reAddIsIdempotent() async throws {
        let (store, _, keychain) = freshStore()

        let id1 = try await store.addSMBServer(smbData(shares: ["Media"]), password: "old-pass")
        let id2 = try await store.addSMBServer(smbData(shares: ["Media", "TV"]), password: "new-pass")

        // Same id — host-keyed
        #expect(id1 == id2)

        // Only one server row — no duplicate
        let servers = await store.servers
        #expect(servers.count == 1)

        // Shares updated to the latest add
        guard let server = servers.first, case .smb(let stored) = server.kind else {
            Issue.record("expected one .smb PersistedServer")
            return
        }
        #expect(stored.shares == ["Media", "TV"])

        // Password updated
        let storedPassword: String? = try await keychain.read(tokenKey(for: id1))
        #expect(storedPassword == "new-pass")
    }

    @Test("remove of an SMB server removes it from servers and deletes its Keychain password slot")
    func removeDeletesPasswordSlot() async throws {
        let (store, _, keychain) = freshStore()
        let data = smbData()

        let id = try await store.addSMBServer(data, password: "s3cr3t")
        try await store.remove(id)

        // Gone from servers
        let servers = await store.servers
        #expect(servers.contains(where: { $0.id == id }) == false)

        // Password slot deleted
        let storedPassword: String? = try await keychain.read(tokenKey(for: id))
        #expect(storedPassword == nil)

        // FakeKeychain records the delete call, keyed through the production slot helper.
        #expect(keychain.deleteCalls.contains(ServerStore.tokenAccount(for: id)))
    }

    @Test("hasSMBServers reflects SMB presence and ignores Jellyfin-only configs")
    func hasSMBServersTracksSMBOnly() async throws {
        let (store, _, _) = freshStore()

        // Empty store: no SMB.
        var hasSMB = await store.hasSMBServers
        #expect(hasSMB == false)

        // A Jellyfin session alone must NOT count as an SMB source (it drives login-vs-home
        // via the active session, not the auxiliary-source flag).
        try await store.add(sampleSession())
        hasSMB = await store.hasSMBServers
        #expect(hasSMB == false)

        // Adding an SMB server flips it true.
        let id = try await store.addSMBServer(smbData(), password: "pw")
        hasSMB = await store.hasSMBServers
        #expect(hasSMB == true)

        // Removing the SMB server flips it back (the Jellyfin session remains).
        try await store.remove(id)
        hasSMB = await store.hasSMBServers
        #expect(hasSMB == false)
    }

    @Test("setShares replaces an SMB server's shares and leaves its password intact")
    func setSharesUpdatesShares() async throws {
        let (store, _, keychain) = freshStore()
        let id = try await store.addSMBServer(smbData(shares: ["Media"]), password: "pw")

        try await store.setShares(["Media", "TV", "Music"], for: id)

        let servers = await store.servers
        guard let server = servers.first(where: { $0.id == id }),
              case .smb(let data) = server.kind else {
            Issue.record("expected the .smb server"); return
        }
        #expect(data.shares == ["Media", "TV", "Music"])
        let pw: String? = try await keychain.read(tokenKey(for: id))
        #expect(pw == "pw")
    }

    @Test("setShares is a no-op for an unknown id and for a non-SMB (Jellyfin) server")
    func setSharesNoOpForNonSMB() async throws {
        let (store, _, _) = freshStore()
        try await store.add(sampleSession(id: "jf-1"))
        let smbID = try await store.addSMBServer(smbData(shares: ["Media"]), password: "pw")

        try await store.setShares(["X"], for: ServerID(rawValue: "jf-1"))           // non-SMB
        try await store.setShares(["X"], for: ServerID(rawValue: "does-not-exist")) // unknown

        let servers = await store.servers
        #expect(servers.count == 2)
        #expect(servers.contains { $0.id == ServerID(rawValue: "jf-1") && isJellyfin($0) })
        guard let smb = servers.first(where: { $0.id == smbID }),
              case .smb(let d) = smb.kind else {
            Issue.record("smb server missing or wrong kind"); return
        }
        #expect(d.shares == ["Media"])   // untouched
    }

    // MARK: - updateSMBPassword

    /// Marker thrown by the test verifier so a refusal is distinguishable from any other failure.
    private struct VerificationRefused: Error {}

    /// What the store handed the verification probe. A reference box because the probe is a
    /// `@Sendable` closure and a captured `var` can't be mutated from one; the tests read it only
    /// after the (serialised) call returns.
    private final class VerifyProbe: @unchecked Sendable {
        var data: SMBServerData?
        var password: String?
        var wasCalled = false

        func record(_ data: SMBServerData, _ password: String) {
            self.data = data
            self.password = password
            wasCalled = true
        }
    }

    @Test("updateSMBPassword stores the new password under the existing slot and leaves the row untouched")
    func updatePasswordStoresUnderSameSlot() async throws {
        let (store, _, keychain) = freshStore()
        let id = try await store.addSMBServer(smbData(shares: ["Media"]), password: "old-pass")

        let probe = VerifyProbe()
        try await store.updateSMBPassword("new-pass", for: id) { data, password in
            probe.record(data, password)
        }

        // Verified against the PERSISTED identity — the caller's probe never has to be handed the
        // host/account separately (and so can't be handed a stale copy of them).
        #expect(probe.data?.host == "nas.local")
        #expect(probe.data?.username == "alice")
        #expect(probe.password == "new-pass")

        // Same account key `addSMBServer` wrote — a second slot would leave the reader reading the
        // dead one forever.
        let stored: String? = try await keychain.read(tokenKey(for: id))
        #expect(stored == "new-pass")
        #expect(try await store.smbPassword(for: id) == "new-pass")

        // The row itself is untouched: one server, same id, same shares.
        let servers = await store.servers
        #expect(servers.count == 1)
        guard let server = servers.first, case .smb(let data) = server.kind else {
            Issue.record("expected the .smb PersistedServer"); return
        }
        #expect(server.id == id)
        #expect(data.shares == ["Media"])
    }

    @Test("A refused verification rethrows and leaves the stored password untouched")
    func updatePasswordRefusedKeepsOldSecret() async throws {
        let (store, _, keychain) = freshStore()
        let id = try await store.addSMBServer(smbData(), password: "old-pass")
        let storeCallsBefore = keychain.storeCalls.count

        await #expect(throws: VerificationRefused.self) {
            try await store.updateSMBPassword("wrong-pass", for: id) { _, _ in
                throw VerificationRefused()
            }
        }

        // Not merely "not overwritten" — never WRITTEN: a failed attempt must not touch the slot.
        #expect(keychain.storeCalls.count == storeCallsBefore)
        let stored: String? = try await keychain.read(tokenKey(for: id))
        #expect(stored == "old-pass")
    }

    /// The password slot is only ever meaningful for a persisted SMB row, so both non-SMB ids are
    /// refused the same way — writing one would leave a secret nothing references (and, for the
    /// Jellyfin case, would clobber a live bearer token, since both kinds share the slot naming).
    @Test(
        "updateSMBPassword refuses an id that isn't a persisted SMB server, without verifying or writing",
        arguments: ["jf-1", "does-not-exist"]
    )
    func updatePasswordRejectsNonSMBIDs(rawID: String) async throws {
        let (store, _, keychain) = freshStore()
        let session = sampleSession(id: "jf-1", token: "tok-jf")
        try await store.add(session)
        let storeCallsBefore = keychain.storeCalls.count

        let probe = VerifyProbe()
        // The specific case, not just the type — `.persistenceFailed` passing here would let the
        // guard silently regress into a late write failure.
        let thrown = await #expect(throws: ServerStore.ServerStoreError.self) {
            try await store.updateSMBPassword("pw", for: ServerID(rawValue: rawID)) { data, password in
                probe.record(data, password)
            }
        }
        guard case .notAnSMBServer(let refusedID) = thrown else {
            Issue.record("expected .notAnSMBServer, got \(String(describing: thrown))"); return
        }
        #expect(refusedID == rawID)

        #expect(probe.wasCalled == false)
        #expect(keychain.storeCalls.count == storeCallsBefore)
        // The Jellyfin token in the identically-named slot survives.
        let token: String? = try await keychain.read(tokenKey(for: session.id))
        #expect(token == "tok-jf")
    }

    /// The guard must hold AFTER the verify suspension too: `verify` suspends the actor, so a
    /// concurrent `remove` can win the race and delete both the row and the slot before the probe
    /// returns. Writing anyway would re-create a secret nothing references. Modeled directly: the
    /// probe itself removes the server (actor reentrancy makes that legal), which is exactly the
    /// interleaving of a user tapping Remove Server while the recovery form is verifying.
    @Test("A server removed while verification is in flight is refused the late write")
    func updatePasswordRefusesWriteAfterConcurrentRemove() async throws {
        let (store, _, keychain) = freshStore()
        let id = try await store.addSMBServer(smbData(), password: "old-pass")

        let thrown = await #expect(throws: ServerStore.ServerStoreError.self) {
            try await store.updateSMBPassword("new-pass", for: id) { _, _ in
                try await store.remove(id)
            }
        }
        guard case .notAnSMBServer = thrown else {
            Issue.record("expected .notAnSMBServer, got \(String(describing: thrown))"); return
        }

        // The remove's deletion is the last word — no resurrected slot, no ghost row.
        let stored: String? = try await keychain.read(tokenKey(for: id))
        #expect(stored == nil)
        #expect(await store.servers.isEmpty)
    }

    @Test("SMB server and Jellyfin session coexist: both in servers, only Jellyfin in sessions, active unchanged")
    func smbAndJellyfinCoexist() async throws {
        let (store, _, keychain) = freshStore()
        let jfSession = sampleSession()

        // Add Jellyfin first so it becomes active
        try await store.add(jfSession)
        let smbData = smbData()
        let smbID = try await store.addSMBServer(smbData, password: "pw")

        let servers = await store.servers
        #expect(servers.count == 2)
        #expect(servers.contains(where: { $0.id == jfSession.id }))
        #expect(servers.contains(where: { $0.id == smbID }))

        // Only the Jellyfin server appears in sessions
        let sessions = await store.sessions
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == jfSession.id)

        // active is still the Jellyfin session — addSMBServer must not change it
        let active = await store.active
        #expect(active?.id == jfSession.id)

        // Jellyfin token still intact
        let jfToken: String? = try await keychain.read(tokenKey(for: jfSession.id))
        #expect(jfToken == jfSession.accessToken)
    }
}

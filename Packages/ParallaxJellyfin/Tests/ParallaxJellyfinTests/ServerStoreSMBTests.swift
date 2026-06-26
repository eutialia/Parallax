import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("ServerStore SMB write path")
struct ServerStoreSMBTests {
    // MARK: - Helpers

    private func freshStore() -> (ServerStore, SettingsStore, FakeKeychain) {
        let suiteName = "ServerStoreSMBTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        let keychain = FakeKeychain()
        let store = ServerStore(settings: settings, keychain: keychain)
        return (store, settings, keychain)
    }

    private func smbData(
        host: String = "nas.local",
        shares: [String] = ["Media", "Backups"]
    ) -> SMBServerData {
        SMBServerData(host: host, username: "alice", domain: "WORKGROUP", shares: shares)
    }

    private func sampleSession(id: String = "jf-1", token: String = "tok-jf") -> Session {
        let data = JellyfinServerData(
            serverURL: URL(string: "https://\(id).example.com")!,
            serverName: "Server \(id)",
            user: UserSnapshot(id: "u-\(id)", name: "alice", serverLastUpdatedAt: nil)
        )
        return Session(id: ServerID(rawValue: id), data: data, accessToken: token)
    }

    private func tokenKey(for id: ServerID) -> KeychainKey<String> {
        KeychainKey<String>(account: "token-\(id.rawValue)")
    }

    // MARK: - Tests

    @Test("addSMBServer persists .smb PersistedServer, stores password in Keychain, does not touch sessions or active")
    func addPersistsServerAndPassword() async throws {
        let (store, _, keychain) = freshStore()
        let data = smbData()

        let id = try await store.addSMBServer(data, password: "s3cr3t")

        // ID scheme: "smb-<host>"
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

        // FakeKeychain records the delete call
        #expect(keychain.deleteCalls.contains("token-\(id.rawValue)"))
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
        #expect(servers.contains {
            $0.id == ServerID(rawValue: "jf-1") && {
                if case .jellyfin = $0.kind { return true }
                return false
            }($0)
        })
        guard let smb = servers.first(where: { $0.id == smbID }),
              case .smb(let d) = smb.kind else {
            Issue.record("smb server missing or wrong kind"); return
        }
        #expect(d.shares == ["Media"])   // untouched
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

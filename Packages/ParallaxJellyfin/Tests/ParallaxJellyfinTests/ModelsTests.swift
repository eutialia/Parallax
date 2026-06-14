import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("Domain models")
struct ModelsTests {
    @Test("ServerID is value-equal and hashable on raw string")
    func serverIDEquality() {
        let a = ServerID(rawValue: "abc")
        let b = ServerID(rawValue: "abc")
        let c = ServerID(rawValue: "xyz")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test("PersistedServer round-trips through JSON")
    func persistedServerCodable() throws {
        let server = PersistedServer(
            id: ServerID(rawValue: "server-1"),
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://jellyfin.example.com")!,
                serverName: "Living Room",
                user: UserSnapshot(id: "user-1", name: "alice", serverLastUpdatedAt: nil)
            ))
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PersistedServer.self, from: data)
        #expect(decoded == server)
    }

    @Test("PersistedServer SMB kind round-trips (password not persisted here)")
    func persistedServerSMBCodable() throws {
        let server = PersistedServer(
            id: ServerID(rawValue: "nas-1"),
            kind: .smb(SMBServerData(
                host: "192.168.1.10",
                share: "Media",
                root: "Movies",
                username: "guest",
                domain: "WORKGROUP"
            ))
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PersistedServer.self, from: data)
        #expect(decoded == server)
        guard case .smb(let smb) = decoded.kind else {
            Issue.record("expected .smb kind"); return
        }
        #expect(smb.host == "192.168.1.10")
        #expect(smb.share == "Media")
    }

    @Test("Jellyfin server data decodes legacy user primaryImageTag without failing")
    func jellyfinDataIgnoresLegacyProfileImageTag() throws {
        // UserSnapshot must tolerate an extra (now-dropped) field carried by an
        // older server's user blob — decoding extra keys must not throw.
        let json = """
        {"id":"user-1","name":"alice","primaryImageTag":"abc123","serverLastUpdatedAt":null}
        """
        let decoded = try JSONDecoder().decode(UserSnapshot.self, from: Data(json.utf8))
        #expect(decoded.name == "alice")
        #expect(decoded.id == "user-1")
    }

    @Test("Session combines a .jellyfin PersistedServer with a token")
    func sessionAttachesToken() throws {
        let data = JellyfinServerData(
            serverURL: URL(string: "https://j.example.com")!,
            serverName: "Home",
            user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
        )
        let session = Session(id: ServerID(rawValue: "s1"), data: data, accessToken: "tok-123")
        #expect(session.id == ServerID(rawValue: "s1"))
        #expect(session.serverURL == data.serverURL)
        #expect(session.serverName == data.serverName)
        #expect(session.user == data.user)
        #expect(session.accessToken == "tok-123")

        // An .smb PersistedServer never produces a Session.
        let smbServer = PersistedServer(
            id: ServerID(rawValue: "nas-1"),
            kind: .smb(SMBServerData(host: "h", share: "s", root: "", username: "u", domain: "d"))
        )
        #expect(Session(persisted: smbServer, accessToken: "pw") == nil)
    }

    @Test("QuickConnectStatus cases are distinguishable")
    func quickConnectStatusCases() {
        let waiting = QuickConnectStatus.waitingForCode
        let polling = QuickConnectStatus.polling(code: "ABC123")
        let expired = QuickConnectStatus.expired
        let failed = QuickConnectStatus.failed(reason: "boom")
        #expect(waiting != polling)
        #expect(polling != expired)
        #expect(expired != failed)
        if case .polling(let code) = polling {
            #expect(code == "ABC123")
        } else {
            Issue.record("expected .polling")
        }
        if case .failed(let reason) = failed {
            #expect(reason == "boom")
        } else {
            Issue.record("expected .failed")
        }
    }
}

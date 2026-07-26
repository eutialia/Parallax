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

    /// The persisted shape is on-disk data: a round-trip failure for either kind logs the user out
    /// of that source on the next launch, so both kinds are checked through one assertion.
    @Test(
        "Every PersistedServer kind round-trips through JSON",
        arguments: [
            PersistedServer(id: ServerID(rawValue: "server-1"), kind: .jellyfin(JellyfinFixtures.jellyfinData(id: "server-1"))),
            PersistedServer(id: ServerID(rawValue: "nas-1"), kind: .smb(JellyfinFixtures.smbData(host: "192.168.1.10"))),
        ]
    )
    func persistedServerCodable(server: PersistedServer) throws {
        let decoded = try JSONDecoder().decode(
            PersistedServer.self,
            from: try JSONEncoder().encode(server)
        )
        #expect(decoded == server)
    }

    /// An older server's user blob still carries a `primaryImageTag` this app dropped. Decoding
    /// must tolerate the extra key rather than throw and take the whole server list down with it.
    @Test("UserSnapshot tolerates a dropped legacy field in stored JSON")
    func userSnapshotIgnoresLegacyProfileImageTag() throws {
        let json = """
        {"id":"user-1","name":"alice","primaryImageTag":"abc123","serverLastUpdatedAt":null}
        """
        let decoded = try JSONDecoder().decode(UserSnapshot.self, from: Data(json.utf8))
        #expect(decoded.name == "alice")
        #expect(decoded.id == "user-1")
    }

    /// A `Session` exists only for Jellyfin: an SMB row persists the same way but has no API
    /// surface to drive, so building one from it must fail rather than produce a session whose
    /// every request would be nonsense.
    @Test("Session is built from a .jellyfin row and refused for an .smb one")
    func sessionOnlyFromJellyfinRow() throws {
        let data = JellyfinFixtures.jellyfinData(id: "s1")
        let session = Session(id: ServerID(rawValue: "s1"), data: data, accessToken: "tok-123")
        #expect(session.id == ServerID(rawValue: "s1"))
        #expect(session.serverURL == data.serverURL)
        #expect(session.serverName == data.serverName)
        #expect(session.user == data.user)
        #expect(session.accessToken == "tok-123")

        // Round-tripping through the persisted row rebuilds the same session.
        let rebuilt = Session(persisted: session.persisted, accessToken: "tok-123")
        #expect(rebuilt == session)

        let smbServer = PersistedServer(id: ServerID(rawValue: "nas-1"), kind: .smb(JellyfinFixtures.smbData()))
        #expect(Session(persisted: smbServer, accessToken: "pw") == nil)
    }
}

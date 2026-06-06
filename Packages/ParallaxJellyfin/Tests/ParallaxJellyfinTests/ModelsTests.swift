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

    @Test("PersistedSession round-trips through JSON")
    func persistedSessionCodable() throws {
        let session = PersistedSession(
            id: ServerID(rawValue: "server-1"),
            serverURL: URL(string: "https://jellyfin.example.com")!,
            serverName: "Living Room",
            user: UserSnapshot(id: "user-1", name: "alice", serverLastUpdatedAt: nil)
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PersistedSession.self, from: data)
        #expect(decoded == session)
    }

    @Test("PersistedSession decodes legacy user primaryImageTag without failing")
    func persistedSessionIgnoresLegacyProfileImageTag() throws {
        let json = """
        {"id":"server-1","serverURL":"https:\\/\\/jellyfin.example.com","serverName":"Home",\
        "user":{"id":"user-1","name":"alice","primaryImageTag":"abc123","serverLastUpdatedAt":null}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(PersistedSession.self, from: data)
        #expect(decoded.user.name == "alice")
        #expect(decoded.user.id == "user-1")
    }

    @Test("Session combines PersistedSession with a token")
    func sessionAttachesToken() {
        let persisted = PersistedSession(
            id: ServerID(rawValue: "s1"),
            serverURL: URL(string: "https://j.example.com")!,
            serverName: "Home",
            user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
        )
        let session = Session(persisted: persisted, accessToken: "tok-123")
        #expect(session.id == persisted.id)
        #expect(session.serverURL == persisted.serverURL)
        #expect(session.serverName == persisted.serverName)
        #expect(session.user == persisted.user)
        #expect(session.accessToken == "tok-123")
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

import Foundation
import Testing
import Nuke
@testable import ParallaxJellyfin

@Suite("ImagePipelineFactory")
struct ImagePipelineFactoryTests {
    private func session(id: String, token: String) -> Session {
        Session(
            persisted: PersistedSession(
                id: ServerID(rawValue: id),
                serverURL: URL(string: "https://\(id).example.com")!,
                serverName: id,
                user: UserSnapshot(id: "u-\(id)", name: "alice", serverLastUpdatedAt: nil)
            ),
            accessToken: token
        )
    }

    private func identity() -> DeviceIdentity {
        DeviceIdentity(client: "Parallax", deviceName: "iPhone Test", deviceID: "test-dev-id", version: "0.3.0")
    }

    @Test("Same session returns the same pipeline instance (memoised)")
    func memoised() async {
        let factory = ImagePipelineFactory(identity: identity())
        let s = session(id: "a", token: "tok-a")
        let p1 = await factory.pipeline(for: s)
        let p2 = await factory.pipeline(for: s)
        #expect(p1 === p2)
    }

    @Test("Different sessions return different pipelines")
    func perSession() async {
        let factory = ImagePipelineFactory(identity: identity())
        let p1 = await factory.pipeline(for: session(id: "a", token: "tok-a"))
        let p2 = await factory.pipeline(for: session(id: "b", token: "tok-b"))
        #expect(p1 !== p2)
    }

    @Test("Authorization header builder includes Token and Client metadata")
    func authHeader() {
        let header = ImagePipelineFactory.authorizationHeader(identity: identity(), token: "tok-abc")
        #expect(header.contains("Client=\"Parallax\""))
        #expect(header.contains("DeviceId=\"test-dev-id\""))
        #expect(header.contains("Version=\"0.3.0\""))
        #expect(header.contains("Token=\"tok-abc\""))
        #expect(header.hasPrefix("MediaBrowser "))
    }
}

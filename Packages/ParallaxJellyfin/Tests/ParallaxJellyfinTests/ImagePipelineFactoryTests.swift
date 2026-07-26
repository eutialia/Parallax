import Foundation
import Testing
import Nuke
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("ImagePipelineFactory")
struct ImagePipelineFactoryTests {
    /// A private, purged defaults suite rather than `.standard` — the provider persists a device
    /// id, and a shared domain would leak one test's id into the next run.
    private func provider() -> DeviceIdentityProvider {
        let (settings, _) = JellyfinFixtures.settingsStore("ImagePipelineFactoryTests")
        return DeviceIdentityProvider(
            client: "Parallax",
            deviceName: "iPhone Test",
            version: "0.3.0",
            settings: settings
        )
    }

    /// A rotated token must produce a fresh pipeline: the old one's URLSession carries the dead
    /// token in its additional headers, so every image request would keep 401ing.
    @Test("Pipelines are memoized per server and rebuilt on a rotated token")
    func memoizationContract() async {
        let factory = ImagePipelineFactory(identityProvider: provider())
        await verifyMemoization { await factory.pipeline(for: $0) }
    }

    @Test("Authorization header builder includes Token and Client metadata")
    func authHeader() {
        let identity = JellyfinFixtures.identity(
            client: "Parallax",
            deviceName: "iPhone Test",
            deviceID: "test-dev-id",
            version: "0.3.0"
        )
        let header = ImagePipelineFactory.authorizationHeader(identity: identity, token: "tok-abc")
        #expect(header.hasPrefix("MediaBrowser "))
        #expect(header.contains("Client=\"\(identity.client)\""))
        #expect(header.contains("Device=\"\(identity.deviceName)\""))
        #expect(header.contains("DeviceId=\"\(identity.deviceID)\""))
        #expect(header.contains("Version=\"\(identity.version)\""))
        #expect(header.contains("Token=\"tok-abc\""))
    }
}

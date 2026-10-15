import Foundation
import Testing
import Nuke
import ParallaxCore
import ParallaxJellyfinTestSupport
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

    /// A scratch directory, so a test's pipelines never write into the real Caches directory.
    private func cacheDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "ImagePipelineFactoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A rotated token must produce a fresh pipeline: the old one's URLSession carries the dead
    /// token in its additional headers, so every image request would keep 401ing.
    @Test("Pipelines are memoized per server and rebuilt on a rotated token")
    func memoizationContract() async {
        let caches = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: caches) }
        let factory = ImagePipelineFactory(identityProvider: provider(), cacheDirectory: caches)
        await verifyMemoization { await factory.pipeline(for: $0) }
    }

    /// The configuration is the one every API client shares, so the token header has to land on
    /// the pipeline's own copy of it. The disk cache goes where the caller says, one directory
    /// per server.
    @Test("Image bytes go out on the injected transport with the session's token, and the configuration stays clean")
    func imageDataUsesTheInjectedTransport() async throws {
        let stub = StubHTTPTransport()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        stub.always(.init(headers: ["Content-Type": "image/png"], body: bytes))
        let configuration = stub.configuration
        let caches = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: caches) }
        let factory = ImagePipelineFactory(
            identityProvider: provider(), sessionConfiguration: configuration, cacheDirectory: caches
        )
        let session = JellyfinFixtures.session(token: "tok-img", serverURL: stub.baseURL)
        let ref = ImageRef(itemID: ItemID(rawValue: "item-1"), kind: .primary, tag: ImageTag(rawValue: "t1"))

        let data = await factory.imageData(for: ref, session: session, maxWidth: 64)

        #expect(data == bytes)
        let exchange = try stub.onlyExchange()
        #expect(exchange.path == "/Items/item-1/Images/Primary")
        #expect(exchange.headers["Authorization"]?.contains("Token=\"tok-img\"") == true)
        #expect(exchange.headers["X-Emby-Authorization"] == nil)
        #expect(configuration.httpAdditionalHeaders == nil)
        let cache = await factory.pipeline(for: session).configuration.dataCache as? DataCache
        #expect(cache?.path.standardizedFileURL == caches.appending(path: "com.lhdev.parallax.images.s1").standardizedFileURL)
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

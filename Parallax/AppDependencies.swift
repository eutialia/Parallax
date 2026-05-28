import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class AppDependencies {
    let serverStore: ServerStore
    let sessionManager: SessionManager
    let deviceIdentityProvider: DeviceIdentityProvider
    let lanDiscovery: LANServerDiscovery
    let libraryRepoFactory: @Sendable (Session) async -> LibraryRepository
    let imagePipelineFactory: ImagePipelineFactory

    init(
        serverStore: ServerStore,
        sessionManager: SessionManager,
        deviceIdentityProvider: DeviceIdentityProvider,
        lanDiscovery: LANServerDiscovery,
        libraryRepoFactory: @Sendable @escaping (Session) async -> LibraryRepository,
        imagePipelineFactory: ImagePipelineFactory
    ) {
        self.serverStore = serverStore
        self.sessionManager = sessionManager
        self.deviceIdentityProvider = deviceIdentityProvider
        self.lanDiscovery = lanDiscovery
        self.libraryRepoFactory = libraryRepoFactory
        self.imagePipelineFactory = imagePipelineFactory
    }

    static func live() -> AppDependencies {
        let settings = SettingsStore()
        let keychain = Keychain(service: "com.lhdev.parallax")
        let store = ServerStore(settings: settings, keychain: keychain)
        let identity = DeviceIdentityProvider(
            client: "Parallax",
            deviceName: "iOS Device",
            version: appVersion(),
            settings: settings
        )
        let authFactory = DefaultJellyfinClientFactory(identityProvider: identity)
        let manager = SessionManager(serverStore: store, factory: authFactory)
        let libraryClientFactory = DefaultJellyfinLibraryClientFactory(identityProvider: identity)

        // One repo per server, reused across every screen (see
        // LibraryRepositoryStore). The factory closure just delegates so call
        // sites keep their `await deps.libraryRepoFactory(session)` shape.
        let repoStore = LibraryRepositoryStore(clientFactory: libraryClientFactory)
        let repoFactory: @Sendable (Session) async -> LibraryRepository = { session in
            await repoStore.repository(for: session)
        }

        return AppDependencies(
            serverStore: store,
            sessionManager: manager,
            deviceIdentityProvider: identity,
            lanDiscovery: LANServerDiscovery(),
            libraryRepoFactory: repoFactory,
            // Resolve the image-pipeline device identity from the same provider
            // as auth, so image traffic presents the persisted deviceID rather
            // than a per-launch random UUID.
            imagePipelineFactory: ImagePipelineFactory(identityProvider: identity)
        )
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return short
    }
}

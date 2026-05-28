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

        // Build the per-session library repo factory once. Captures
        // libraryClientFactory; each invocation produces a fresh repo.
        let repoFactory: @Sendable (Session) async -> LibraryRepository = { session in
            let client = await libraryClientFactory.make(for: session)
            return LibraryRepository(session: session, client: client)
        }

        // ImagePipelineFactory needs DeviceIdentity synchronously at construction,
        // but DeviceIdentityProvider.current() is async and can't be awaited here.
        //
        // Convergence with the auth deviceID is not straightforward: SettingsStore
        // persists values as JSON-encoded Data (not raw strings), so a synchronous
        // UserDefaults.string(forKey:) read would miss the persisted value. Rather
        // than duplicating JSON decoding logic, we use a dedicated UUID for the
        // image pipeline identity. Jellyfin image endpoints include the token for
        // auth but do not validate deviceID consistency against the session that
        // authenticated — so this divergence is harmless in practice.
        let imagePipelineIdentity = DeviceIdentity(
            client: "Parallax",
            deviceName: "iOS Device",
            deviceID: UUID().uuidString,
            version: appVersion()
        )

        return AppDependencies(
            serverStore: store,
            sessionManager: manager,
            deviceIdentityProvider: identity,
            lanDiscovery: LANServerDiscovery(),
            libraryRepoFactory: repoFactory,
            imagePipelineFactory: ImagePipelineFactory(identity: imagePipelineIdentity)
        )
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return short
    }
}

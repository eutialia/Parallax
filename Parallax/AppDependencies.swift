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

    init(
        serverStore: ServerStore,
        sessionManager: SessionManager,
        deviceIdentityProvider: DeviceIdentityProvider,
        lanDiscovery: LANServerDiscovery
    ) {
        self.serverStore = serverStore
        self.sessionManager = sessionManager
        self.deviceIdentityProvider = deviceIdentityProvider
        self.lanDiscovery = lanDiscovery
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
        let factory = DefaultJellyfinClientFactory(identityProvider: identity)
        let manager = SessionManager(serverStore: store, factory: factory)
        return AppDependencies(
            serverStore: store,
            sessionManager: manager,
            deviceIdentityProvider: identity,
            lanDiscovery: LANServerDiscovery()
        )
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return short
    }
}

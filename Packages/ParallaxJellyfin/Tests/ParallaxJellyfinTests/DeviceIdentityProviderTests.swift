import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DeviceIdentityProvider")
struct DeviceIdentityProviderTests {
    private func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "DeviceIdentityProviderTests-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description)
        return suite
    }

    @Test("First vend creates and persists a stable device ID")
    func firstVendPersistsID() async throws {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        let provider = DeviceIdentityProvider(
            client: "Parallax",
            deviceName: "Test Device",
            version: "0.2.0",
            settings: store
        )

        let identity1 = await provider.current()
        let identity2 = await provider.current()

        #expect(identity1.deviceID == identity2.deviceID)
        #expect(!identity1.deviceID.isEmpty)
        #expect(identity1.client == "Parallax")
        #expect(identity1.deviceName == "Test Device")
        #expect(identity1.version == "0.2.0")
    }

    @Test("A new provider reads the same ID back from settings")
    func idSurvivesProviderRecreation() async throws {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)

        let firstID = await DeviceIdentityProvider(
            client: "Parallax", deviceName: "Test", version: "0.2.0", settings: store
        ).current().deviceID

        let secondID = await DeviceIdentityProvider(
            client: "Parallax", deviceName: "Test", version: "0.2.0", settings: store
        ).current().deviceID

        #expect(firstID == secondID)
    }
}

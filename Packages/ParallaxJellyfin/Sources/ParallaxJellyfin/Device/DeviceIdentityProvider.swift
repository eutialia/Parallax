import Foundation
import ParallaxCore

public actor DeviceIdentityProvider {
    private static let deviceIDKey = SettingKey<String?>(name: "ParallaxJellyfin.deviceID", defaultValue: nil)

    private let client: String
    private let deviceName: String
    private let version: String
    private let settings: SettingsStore

    private var cached: DeviceIdentity?

    public init(client: String, deviceName: String, version: String, settings: SettingsStore) {
        self.client = client
        self.deviceName = deviceName
        self.version = version
        self.settings = settings
    }

    public func current() async -> DeviceIdentity {
        if let cached { return cached }

        let storedID = await settings.value(for: Self.deviceIDKey)
        let deviceID: String
        if let storedID {
            deviceID = storedID
        } else {
            let newID = UUID().uuidString
            // Encoding a String? cannot fail; surface but don't crash if it
            // somehow does — we'd rather log and use the in-memory ID than
            // refuse to sign the user in.
            do {
                try await settings.set(Optional(newID), for: Self.deviceIDKey)
            } catch {
                Log.persistence.error("DeviceIdentityProvider: failed to persist deviceID — \(error.localizedDescription)")
            }
            deviceID = newID
        }

        let identity = DeviceIdentity(client: client, deviceName: deviceName, deviceID: deviceID, version: version)
        cached = identity
        return identity
    }
}

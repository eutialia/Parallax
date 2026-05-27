import Foundation
import ParallaxCore

public actor DeviceIdentityProvider {
    private static let deviceIDKey = SettingKey<String?>(name: "ParallaxJellyfin.deviceID", defaultValue: nil)

    private let client: String
    private let deviceName: String
    private let version: String
    private let settings: SettingsStore

    /// Concurrent callers must observe the same DeviceIdentity. A plain
    /// `cached: DeviceIdentity?` would race: caller A awaits `settings.value`
    /// and yields the actor; caller B enters at the same `if let cached`
    /// check, also sees nil, generates a different UUID, persists it. The
    /// in-process ID would then disagree with the persisted one. Storing the
    /// produce-once Task instead makes both callers await the same result.
    private var resolution: Task<DeviceIdentity, Never>?

    public init(client: String, deviceName: String, version: String, settings: SettingsStore) {
        self.client = client
        self.deviceName = deviceName
        self.version = version
        self.settings = settings
    }

    public func current() async -> DeviceIdentity {
        if let resolution { return await resolution.value }
        let task = Task { await resolveIdentity() }
        resolution = task
        return await task.value
    }

    private func resolveIdentity() async -> DeviceIdentity {
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
        return DeviceIdentity(client: client, deviceName: deviceName, deviceID: deviceID, version: version)
    }
}

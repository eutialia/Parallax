import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DeviceIdentityProvider")
struct DeviceIdentityProviderTests {
    private func provider(settings: SettingsStore) -> DeviceIdentityProvider {
        DeviceIdentityProvider(
            client: "Parallax",
            deviceName: "Test Device",
            version: "0.2.0",
            settings: settings
        )
    }

    /// The device id is what the server attributes sessions to, so it has to be minted once and
    /// then stay put — for the life of the process AND across relaunches. Anything else re-registers
    /// the app as a new device on every launch (and breaks the deviceId-scoped transcode kill).
    @Test("A device id is minted once and read back by a later provider")
    func idIsStableAndPersisted() async {
        let (settings, _) = JellyfinFixtures.settingsStore("DeviceIdentityProviderTests")

        let first = provider(settings: settings)
        let minted = await first.current().deviceID
        #expect(minted.isEmpty == false)
        #expect(await first.current().deviceID == minted, "repeat calls must not re-mint")

        // A fresh provider over the SAME store — i.e. the next launch — reads the persisted id.
        #expect(await provider(settings: settings).current().deviceID == minted)
    }

    /// The produce-once `Task` exists for exactly this: without it two concurrent callers both see
    /// no cached value, both mint a UUID, and the in-process id disagrees with the persisted one.
    @Test("Concurrent first callers observe one id")
    func concurrentCallersAgree() async {
        let (settings, _) = JellyfinFixtures.settingsStore("DeviceIdentityProviderTests-race")
        let subject = provider(settings: settings)

        let ids = await withTaskGroup(of: String.self) { group in
            for _ in 0..<16 {
                group.addTask { await subject.current().deviceID }
            }
            var seen: Set<String> = []
            for await id in group { seen.insert(id) }
            return seen
        }

        #expect(ids.count == 1)
        // And the one they agreed on is the one that got persisted.
        #expect(await provider(settings: settings).current().deviceID == ids.first)
    }

    /// A pre-existing id must be adopted, never overwritten — a fresh one would look like a new
    /// device to every server the user has configured.
    @Test("An already-persisted id is adopted as-is")
    func adoptsPersistedID() async throws {
        let (settings, _) = JellyfinFixtures.settingsStore("DeviceIdentityProviderTests-adopt")
        let seeded = "seeded-device-id"
        try await settings.set(Optional(seeded), for: SettingKey<String?>(name: "ParallaxJellyfin.deviceID", defaultValue: nil))

        #expect(await provider(settings: settings).current().deviceID == seeded)
    }
}

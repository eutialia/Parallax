import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

/// The synchronous SMB-only probe the launch gate consults before the first frame. It reads the
/// same `UserDefaults` blob `load()` does, so these seed through the same fixtures the store's own
/// tests use — a key or encoding drift has to fail here too, not just in the async path.
@Suite("ServerStore SMB-only probe")
struct ServerStoreSMBOnlyProbeTests {
    private func defaults(_ label: String) -> (UserDefaults, String) {
        JellyfinFixtures.freshDefaults("ServerStoreSMBOnlyProbeTests-\(label)")
    }

    private func jellyfin(_ id: String) -> PersistedServer {
        PersistedServer(id: ServerID(rawValue: id), kind: .jellyfin(JellyfinFixtures.jellyfinData()))
    }

    private func smb(_ id: String, host: String = "nas.local") -> PersistedServer {
        PersistedServer(id: ServerID(rawValue: id), kind: .smb(JellyfinFixtures.smbData(host: host)))
    }

    @Test("every persisted server SMB → SMB-only")
    func allSMB() throws {
        let (store, suiteName) = defaults("all-smb")
        try JellyfinFixtures.seedPersistedServers([smb("smb-a"), smb("smb-b", host: "other.local")],
                                                  suiteName: suiteName)
        #expect(ServerStore.persistedSetupIsSMBOnly(defaults: store))
    }

    /// One Jellyfin server is enough to earn the full story: there IS a bootstrap to cover.
    @Test("any Jellyfin server disqualifies it", arguments: [true, false])
    func mixedOrJellyfinOnly(withSMB: Bool) throws {
        let (store, suiteName) = defaults("mixed-\(withSMB)")
        let servers = withSMB ? [jellyfin("jf-1"), smb("smb-a")] : [jellyfin("jf-1")]
        try JellyfinFixtures.seedPersistedServers(servers, suiteName: suiteName)
        #expect(!ServerStore.persistedSetupIsSMBOnly(defaults: store))
    }

    /// A first run has no sources at all — vacuously "no Jellyfin", but emphatically not the
    /// SMB-only case, and exactly the launch that most deserves the full story.
    @Test("a setup with nothing configured is not SMB-only")
    func emptySetup() throws {
        let (store, suiteName) = defaults("empty")
        #expect(!ServerStore.persistedSetupIsSMBOnly(defaults: store))

        try JellyfinFixtures.seedPersistedServers([], suiteName: suiteName)
        #expect(!ServerStore.persistedSetupIsSMBOnly(defaults: store))
    }

    /// Bytes that don't decode as the current shape (a legacy v1 blob, a truncated write) must
    /// answer conservatively rather than guess — the probe never wipes or migrates anything.
    @Test("undecodable bytes fall back to the full story")
    func undecodableBytes() {
        let (store, suiteName) = defaults("garbage")
        JellyfinFixtures.seedPersistedBytes(Data("{ not json".utf8), suiteName: suiteName)
        #expect(!ServerStore.persistedSetupIsSMBOnly(defaults: store))
    }
}

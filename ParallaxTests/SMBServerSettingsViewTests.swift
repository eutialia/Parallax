import Testing
import ParallaxFileBrowse
@testable import Parallax

@Suite("SMB server settings · share reconciliation")
@MainActor
struct SMBServerSettingsViewTests {
    private func share(_ name: String, _ comment: String = "") -> SMBShare {
        SMBShare(name: name, comment: comment)
    }

    @Test("Every enabled share is live → nothing is unavailable")
    func allLive() {
        let unavailable = SMBServerSettingsView.unavailableShares(
            enabled: ["Media", "Photos"],
            live: [share("Media"), share("Photos"), share("Backups")]
        )
        #expect(unavailable.isEmpty)
    }

    @Test("An enabled share the server no longer offers is reported as unavailable")
    func absentShareSurfaces() {
        let unavailable = SMBServerSettingsView.unavailableShares(
            enabled: ["Media", "OldArchive"],
            live: [share("Media"), share("Photos")]
        )
        #expect(unavailable == ["OldArchive"])
    }

    @Test("Unavailable names come back sorted for a stable row order")
    func sortedOrder() {
        let unavailable = SMBServerSettingsView.unavailableShares(
            enabled: ["Zeta", "Alpha", "Mike"],
            live: []
        )
        #expect(unavailable == ["Alpha", "Mike", "Zeta"])
    }

    @Test("A live-but-not-enabled share is never reported unavailable")
    func liveButDisabledIgnored() {
        let unavailable = SMBServerSettingsView.unavailableShares(
            enabled: ["Media"],
            live: [share("Media"), share("Backups")]
        )
        #expect(unavailable.isEmpty)
    }

    @Test("All enabled shares vanished server-side → all are recoverable as unavailable")
    func everyShareGone() {
        let unavailable = SMBServerSettingsView.unavailableShares(
            enabled: ["Media", "Photos"],
            live: []
        )
        #expect(unavailable == ["Media", "Photos"])
    }

    @Test("No enabled shares → nothing unavailable regardless of what's live")
    func noneEnabled() {
        let unavailable = SMBServerSettingsView.unavailableShares(
            enabled: [],
            live: [share("Media"), share("Photos")]
        )
        #expect(unavailable.isEmpty)
    }
}

import Testing
import ParallaxFileBrowse
@testable import Parallax

/// One reconciliation row: what the user has enabled, what the server currently offers, and the
/// names the settings screen must flag as gone. A named case rather than a tuple because Swift
/// Testing only destructures 2-tuples into test parameters.
struct ShareReconciliationCase: Sendable, CustomTestStringConvertible {
    let name: String
    let enabled: Set<String>
    let live: [String]
    let unavailable: [String]
    var testDescription: String { name }
}

private let shareReconciliationCases: [ShareReconciliationCase] = [
    ShareReconciliationCase(
        name: "every enabled share is live",
        enabled: ["Media", "Photos"], live: ["Media", "Photos", "Backups"], unavailable: []
    ),
    ShareReconciliationCase(
        name: "an enabled share the server no longer offers",
        enabled: ["Media", "OldArchive"], live: ["Media", "Photos"], unavailable: ["OldArchive"]
    ),
    // Sorted, not set-ordered: the rows sit in a list, so a per-launch shuffle reads as churn.
    ShareReconciliationCase(
        name: "names come back sorted for a stable row order",
        enabled: ["Zeta", "Alpha", "Mike"], live: [], unavailable: ["Alpha", "Mike", "Zeta"]
    ),
    ShareReconciliationCase(
        name: "a live-but-not-enabled share is never flagged",
        enabled: ["Media"], live: ["Media", "Backups"], unavailable: []
    ),
    ShareReconciliationCase(
        name: "every enabled share vanished server-side",
        enabled: ["Media", "Photos"], live: [], unavailable: ["Media", "Photos"]
    ),
    ShareReconciliationCase(
        name: "nothing enabled, whatever is live",
        enabled: [], live: ["Media", "Photos"], unavailable: []
    ),
]

@Suite("SMB server settings · share reconciliation")
@MainActor
struct SMBServerSettingsViewTests {
    @Test(
        "an enabled share is unavailable exactly when the server stopped offering it",
        arguments: shareReconciliationCases
    )
    func unavailableShares(_ reconciliation: ShareReconciliationCase) {
        let unavailable = SMBServerSettingsView.unavailableShares(
            enabled: reconciliation.enabled,
            live: reconciliation.live.map { SMBShare(name: $0, comment: "") }
        )
        #expect(unavailable == reconciliation.unavailable)
    }
}

/// One focus-relocation row: the state the shares group just settled into, what the user has
/// enabled, and where focus must land. Named for the same reason as `ShareReconciliationCase`.
struct ShareFocusCase: Sendable, CustomTestStringConvertible {
    let name: String
    let state: SMBServerSettingsView.LoadState
    let enabled: Set<String>
    let target: SMBServerSettingsView.ShareFocusTarget?
    var testDescription: String { name }
}

private func shares(_ names: String...) -> [SMBShare] {
    names.map { SMBShare(name: $0, comment: "") }
}

private let shareFocusCases: [ShareFocusCase] = [
    // The ordinary path: rows exist, so focus moves off "Remove Server" and onto the FIRST of them
    // (the list is already name-sorted by `loadShares`, so "first" is the top row on screen).
    ShareFocusCase(
        name: "loaded with live shares → the first live row",
        state: .loaded(shares("Media", "Photos")), enabled: ["Media"], target: .row("Media")
    ),
    // The unavailable rows render BELOW the live ones, so a live share always wins the landing even
    // when the enabled set also names a share the server dropped.
    ShareFocusCase(
        name: "live and unavailable both present → still the first live row",
        state: .loaded(shares("Media")), enabled: ["Media", "OldArchive"], target: .row("Media")
    ),
    // Every enabled share vanished server-side: the group is nothing BUT unavailable rows, and they
    // are the only way to drop the dead libraries — so focus has to reach them.
    ShareFocusCase(
        name: "only unavailable rows → the first unavailable row",
        state: .loaded([]), enabled: ["Zeta", "Alpha"], target: .row("Alpha")
    ),
    // Nothing focusable exists (the group renders the "No shares found" footer), so focus stays
    // wherever the engine left it — moving it would yank the user somewhere arbitrary.
    ShareFocusCase(
        name: "loaded with nothing to show → no relocation",
        state: .loaded([]), enabled: [], target: nil
    ),
    // The failure branch swaps the rows for a Retry button, which is then the group's only stop.
    ShareFocusCase(
        name: "failed → the retry button",
        state: .failed("Couldn't load shares from nas.local."), enabled: ["Media"], target: .retry
    ),
    // Mid-load there are no rows yet; relocating now is the exact bug `.onChange` exists to avoid.
    ShareFocusCase(
        name: "loading → no relocation",
        state: .loading, enabled: ["Media"], target: nil
    ),
]

/// The tvOS focus relocation is not decoration: while the shares load, "Remove Server" is the
/// screen's ONLY focusable row, so focus parks at the bottom and everything that appears above it
/// inherits nothing (DOWN is a dead press). These pin which row each settled state hands focus to.
@Suite("SMB server settings · focus targets")
@MainActor
struct SMBServerSettingsFocusTests {
    @Test("each settled load state maps to exactly one focus landing", arguments: shareFocusCases)
    func focusTarget(_ focusCase: ShareFocusCase) {
        #expect(
            SMBServerSettingsView.focusTarget(for: focusCase.state, enabled: focusCase.enabled)
                == focusCase.target
        )
    }

    /// `focusTarget`'s `.loaded` branch is exactly `firstShareRow`, so the row-picking rule is also
    /// asserted on its own — it's the half that will grow if the group ever gains another row kind.
    @Test("the first row prefers a live share and falls back to the leading unavailable one")
    func firstShareRowPrefersLive() {
        #expect(
            SMBServerSettingsView.firstShareRow(live: shares("Photos", "Media"), enabled: ["Gone"])
                == .row("Photos")
        )
        #expect(
            SMBServerSettingsView.firstShareRow(live: [], enabled: ["Gone", "Archive"])
                == .row("Archive")
        )
        #expect(SMBServerSettingsView.firstShareRow(live: [], enabled: []) == nil)
    }
}

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

import Foundation
@testable import ParallaxFileBrowse

/// A canned-entry fake for `SMBLister`, used in unit tests.
/// Returns the same entries regardless of `share`/`path`.
final class FakeSMBLister: SMBLister, @unchecked Sendable {
    let entries: [SMBDirectoryEntry]
    let shares: [SMBShare]
    private(set) var disconnectCalled = false

    init(entries: [SMBDirectoryEntry], shares: [SMBShare] = []) {
        self.entries = entries
        self.shares = shares
    }

    func listShares() async throws -> [SMBShare] { shares }

    func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        entries
    }

    func disconnect() async {
        disconnectCalled = true
    }
}

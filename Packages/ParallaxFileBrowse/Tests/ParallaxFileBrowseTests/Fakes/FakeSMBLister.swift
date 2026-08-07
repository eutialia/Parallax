import Foundation
@testable import ParallaxFileBrowse

/// A canned-entry fake for `SMBLister`, used in unit tests.
/// Returns the same entries regardless of `share`/`path`.
final class FakeSMBLister: SMBLister, @unchecked Sendable {
    let entries: [SMBDirectoryEntry]
    let shares: [SMBShare]

    init(entries: [SMBDirectoryEntry], shares: [SMBShare] = []) {
        self.entries = entries
        self.shares = shares
    }

    func listShares() async throws -> [SMBShare] { shares }

    func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        entries
    }
}

/// Counts `list(share:path:)` calls on the way through to `inner` — the only way to observe that a
/// listing API did NOT recurse, since a fake that returns the same entries at every level would
/// otherwise look identical whether it was walked once or a hundred times.
final class CountingSMBLister: SMBLister, @unchecked Sendable {
    private let inner: any SMBLister
    private(set) var listCallCount = 0

    init(_ inner: any SMBLister) {
        self.inner = inner
    }

    func listShares() async throws -> [SMBShare] { try await inner.listShares() }

    func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        listCallCount += 1
        return try await inner.list(share: share, path: path)
    }
}

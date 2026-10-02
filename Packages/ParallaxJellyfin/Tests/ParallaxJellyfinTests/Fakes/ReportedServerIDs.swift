import Foundation
@testable import ParallaxJellyfin

/// Collects ids across the validator's `@Sendable` callback boundary.
final class ReportedServerIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ServerID] = []
    var ids: [ServerID] { lock.withLock { storage } }
    func record(_ id: ServerID) { lock.withLock { storage.append(id) } }
}

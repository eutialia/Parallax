import Foundation
@testable import ParallaxJellyfin

/// Collects rejected sessions across the validator's `@Sendable` callback boundary.
final class ReportedRejections: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Session] = []
    var sessions: [Session] { lock.withLock { storage } }
    func record(_ session: Session) { lock.withLock { storage.append(session) } }
}

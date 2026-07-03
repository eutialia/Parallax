import Foundation
import Testing
@testable import Parallax

enum SMBTestFixtures {
    /// Isolated `SMBResumeStore` backed by a per-test `UserDefaults` suite — keeps writes
    /// out of the real standard domain. The domain is removed here (stale runs) so callers
    /// only need to clean up after: `defer { defaults.removePersistentDomain(forName: suite) }`
    /// right after calling this, using a suite name unique to the test.
    static func makeResumeStore(suite: String) throws -> (store: SMBResumeStore, defaults: UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (SMBResumeStore(defaults: defaults), defaults)
    }
}

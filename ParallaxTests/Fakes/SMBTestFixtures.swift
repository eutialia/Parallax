import Foundation
import Testing
@testable import Parallax

enum SMBTestFixtures {
    /// Runs `body` against a resume store on its own `UserDefaults` suite, removing the domain
    /// afterwards however `body` exits. Scoped rather than returned so the cleanup can't be
    /// forgotten — the previous shape needed a hand-written `defer` in every test, and the suite
    /// name (a hand-copied string) could silently drift from the test it belonged to.
    ///
    /// Pass `#function` for `suite` at the call site: it's unique per test and can't go stale.
    /// `isolation` defaults to the caller's actor so a `@MainActor` suite can hand in a closure that
    /// touches MainActor state (view models, engines) without it crossing an actor boundary.
    static func withResumeStore<Result>(
        suite: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (SMBResumeStore) async throws -> Result
    ) async throws -> Result {
        // `#function` includes the parameter list ("belowFloorClears()"), which reads well, but the
        // UUID is what makes it safe: suites run in parallel, and a parameterized test's cases all
        // report the same `#function` — a shared domain would let one case's cleanup wipe another's.
        let suiteName = "SMBTestFixtures.\(suite).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try await body(SMBResumeStore(defaults: defaults))
    }

    /// A thumbnail cache over a fresh temp directory, removed however `body` exits. Scoped for the
    /// same reason as `withResumeStore`: the previous shape needed a hand-written
    /// `makeTempDir` + `defer cleanup` pair in all fourteen tests.
    ///
    /// The eviction knobs pass straight through — small values exercise the sweep without writing
    /// thousands of files.
    static func withThumbnailCache<Result>(
        sizeCapBytes: Int64? = nil,
        trimTargetBytes: Int64? = nil,
        sweepInterval: Int? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (SMBThumbnailCache, URL) async throws -> Result
    ) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smb-thumb-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache: SMBThumbnailCache
        if let sizeCapBytes, let trimTargetBytes, let sweepInterval {
            cache = SMBThumbnailCache(
                directory: directory,
                sizeCapBytes: sizeCapBytes,
                trimTargetBytes: trimTargetBytes,
                sweepInterval: sweepInterval
            )
        } else {
            cache = SMBThumbnailCache(directory: directory)
        }
        return try await body(cache, directory)
    }

    /// An `SMBThumbnailKey` with every field defaulted to the value most tests used, so a test that
    /// varies ONE discriminator says so by passing that one argument.
    static func thumbnailKey(
        serverID: String = "smb-nas",
        share: String = "Media",
        path: String = "Movies/Film.mkv",
        size: Int64 = 1234,
        modifiedAt: Date? = Date(timeIntervalSince1970: 1_000)
    ) -> SMBThumbnailKey {
        SMBThumbnailKey(serverID: serverID, share: share, path: path, size: size, modifiedAt: modifiedAt)
    }

    /// A resume store on a throwaway suite for tests that need one only so the subject stops
    /// reaching for `SMBResumeStore.shared` (which writes the real `UserDefaults.standard`
    /// domain). No cleanup hook: nothing is expected to be written through it.
    static func inertResumeStore() -> SMBResumeStore {
        let suiteName = "SMBTestFixtures.inert-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SMBResumeStore(defaults: defaults)
    }
}

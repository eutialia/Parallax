import Foundation
import Testing
import ParallaxPlayback
@testable import Parallax

@Suite("StartupTuningStore")
struct StartupTuningStoreTests {
    /// Isolated defaults per test: `UserDefaults(suiteName:)` keeps writes out of the
    /// real standard domain, and the domain is removed before (stale runs) and after.
    private func makeStore(suite: String) throws -> (store: StartupTuningStore, defaults: UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (StartupTuningStore(defaults: defaults), defaults)
    }

    @Test("A fresh install (nothing persisted) reads .fastStart, the promoted shipping default")
    func freshInstallDefaultsToFastStart() throws {
        let suite = "StartupTuningStoreTests.freshInstallDefaultsToFastStart"
        let (store, defaults) = try makeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(store.selected == .fastStart)
        #expect(store.selected.tuning == StartupTuning(preferredForwardBufferSeconds: 3))
    }

    @Test("A written profile round-trips through .selected")
    func writtenProfileRoundTrips() throws {
        let suite = "StartupTuningStoreTests.writtenProfileRoundTrips"
        let (store, defaults) = try makeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.selected = .system
        #expect(store.selected == .system)

        // A second store instance over the same defaults sees the same value — the
        // persistence is the UserDefaults domain, not in-memory state.
        let reopened = StartupTuningStore(defaults: defaults)
        #expect(reopened.selected == .system)
    }

    @Test("Named profiles map to the documented StartupTuning values")
    func profilesMapToDocumentedTuning() {
        #expect(StartupProfile.system.tuning == .systemDefault)
        #expect(StartupProfile.fastStart.tuning == StartupTuning(preferredForwardBufferSeconds: 3))
    }

    @Test("A garbage/legacy stored value falls back to .fastStart rather than crashing")
    func unknownStoredValueFallsBackToFastStart() throws {
        let suite = "StartupTuningStoreTests.unknownStoredValueFallsBackToFastStart"
        let (store, defaults) = try makeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("not-a-real-profile", forKey: "debug.startupTuning.v1")
        #expect(store.selected == .fastStart)
    }

    @Test("A device that had the deleted Eager profile selected falls back to .fastStart")
    func deletedEagerRawValueFallsBackToFastStart() throws {
        let suite = "StartupTuningStoreTests.deletedEagerRawValueFallsBackToFastStart"
        let (store, defaults) = try makeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // The exact rawValue the deleted case persisted (device A/B, 2026-07-08).
        defaults.set("fastStartEager", forKey: "debug.startupTuning.v1")
        #expect(store.selected == .fastStart)
    }
}

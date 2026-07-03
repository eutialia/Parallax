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

    @Test("A fresh install (nothing persisted) reads .system, the shipping default")
    func freshInstallDefaultsToSystem() throws {
        let suite = "StartupTuningStoreTests.freshInstallDefaultsToSystem"
        let (store, defaults) = try makeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(store.selected == .system)
        #expect(store.selected.tuning == .systemDefault)
    }

    @Test("A written profile round-trips through .selected")
    func writtenProfileRoundTrips() throws {
        let suite = "StartupTuningStoreTests.writtenProfileRoundTrips"
        let (store, defaults) = try makeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.selected = .fastStartEager
        #expect(store.selected == .fastStartEager)

        // A second store instance over the same defaults sees the same value — the
        // persistence is the UserDefaults domain, not in-memory state.
        let reopened = StartupTuningStore(defaults: defaults)
        #expect(reopened.selected == .fastStartEager)
    }

    @Test("Named profiles map to the documented StartupTuning values")
    func profilesMapToDocumentedTuning() {
        #expect(StartupProfile.system.tuning == .systemDefault)
        #expect(StartupProfile.fastStart.tuning == StartupTuning(
            preferredForwardBufferSeconds: 3, automaticallyWaitsToMinimizeStalling: nil
        ))
        #expect(StartupProfile.fastStartEager.tuning == StartupTuning(
            preferredForwardBufferSeconds: 3, automaticallyWaitsToMinimizeStalling: false
        ))
    }

    @Test("A garbage/legacy stored value falls back to .system rather than crashing")
    func unknownStoredValueFallsBackToSystem() throws {
        let suite = "StartupTuningStoreTests.unknownStoredValueFallsBackToSystem"
        let (store, defaults) = try makeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("not-a-real-profile", forKey: "debug.startupTuning.v1")
        #expect(store.selected == .system)
    }
}

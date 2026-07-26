import Foundation
import Testing
import ParallaxPlayback
@testable import Parallax

@Suite("StartupTuningStore")
struct StartupTuningStoreTests {
    /// Isolated defaults per call: `UserDefaults(suiteName:)` keeps writes out of the real standard
    /// domain, and the domain is removed before (stale runs) and after. Scoped rather than returned
    /// so no test can forget the cleanup, and UUID-suffixed so parameterized cases (which all report
    /// the same `#function`) can't wipe each other's domain mid-run.
    private func withStore<Result>(
        _ label: String = #function,
        _ body: (StartupTuningStore, UserDefaults) throws -> Result
    ) throws -> Result {
        let suite = "StartupTuningStoreTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        return try body(StartupTuningStore(defaults: defaults), defaults)
    }

    @Test("A fresh install (nothing persisted) reads .fastStart, the promoted shipping default")
    func freshInstallDefaultsToFastStart() throws {
        try withStore { store, _ in
            #expect(store.selected == .fastStart)
            #expect(store.selected.tuning == StartupProfile.fastStart.tuning)
        }
    }

    @Test("A written profile round-trips through .selected")
    func writtenProfileRoundTrips() throws {
        try withStore { store, defaults in
            store.selected = .system
            #expect(store.selected == .system)

            // A second store instance over the same defaults sees the same value — the
            // persistence is the UserDefaults domain, not in-memory state.
            let reopened = StartupTuningStore(defaults: defaults)
            #expect(reopened.selected == .system)
        }
    }

    /// The one place the tuning numbers are a spec rather than a mirror: `.fastStart`'s 3-second
    /// forward buffer is the value the 2026-07-08 device A/B measured, and `.system` must stay the
    /// untouched control.
    @Test("Named profiles map to the documented StartupTuning values")
    func profilesMapToDocumentedTuning() {
        #expect(StartupProfile.system.tuning == .systemDefault)
        #expect(StartupProfile.fastStart.tuning == StartupTuning(preferredForwardBufferSeconds: 3))
    }

    @Test(
        "An unmappable stored rawValue falls back to .fastStart rather than crashing",
        arguments: [
            // Garbage, e.g. a hand-edited plist or a value from a future build.
            "not-a-real-profile",
            // The exact rawValue the DELETED "Fast Start (Eager)" case persisted (device A/B,
            // 2026-07-08) — devices that had it selected must migrate, not wedge.
            "fastStartEager",
        ]
    )
    func unmappableStoredValueFallsBackToFastStart(stored: String) throws {
        try withStore { store, defaults in
            // Seeded under the store's OWN key, so a key rename fails this instead of passing
            // vacuously against a key nothing reads.
            defaults.set(stored, forKey: StartupTuningStore.key)
            #expect(store.selected == .fastStart)
        }
    }
}

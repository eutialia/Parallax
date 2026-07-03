import Foundation
import ParallaxPlayback

/// Named AVKit buffering profiles for on-device startup-time A/B testing (Plan C).
/// `.system` is the shipping default — `StartupTuning.systemDefault`, which applies
/// nothing. The other two are the candidates under test; picking a winner on device
/// promotes it to the shipped default in a follow-up, not here.
enum StartupProfile: String, CaseIterable, Sendable {
    case system
    case fastStart
    case fastStartEager

    var tuning: StartupTuning {
        switch self {
        case .system:
            .systemDefault
        case .fastStart:
            StartupTuning(preferredForwardBufferSeconds: 3, automaticallyWaitsToMinimizeStalling: nil)
        case .fastStartEager:
            StartupTuning(preferredForwardBufferSeconds: 3, automaticallyWaitsToMinimizeStalling: false)
        }
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .fastStart: "Fast Start"
        case .fastStartEager: "Fast Start (Eager)"
        }
    }
}

/// Synchronous `UserDefaults`-backed persistence for the selected `StartupProfile`
/// (`debug.startupTuning.v1`). Synchronous by design (mirrors `SMBResumeStore`'s
/// `defaults:` seam, minus the actor): the engine factory in `AppDependencies` reads
/// it inline from a non-async `@Sendable` closure, and `UserDefaults` is already
/// thread-safe, so no actor hop is needed for a handful of infrequent writes.
///
/// The type + read path are release-clean (a chosen profile could ship later as a
/// real setting) — only the picker UI that writes it is `#if DEBUG`.
struct StartupTuningStore: Sendable {
    private static let key = "debug.startupTuning.v1"

    private let defaults: UserDefaults

    /// `defaults` is the test seam — `UserDefaults(suiteName:)` keeps test writes out
    /// of the real standard domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted profile, or `.system` when nothing was ever picked (fresh
    /// install) or the stored value no longer maps to a known case.
    var selected: StartupProfile {
        get {
            defaults.string(forKey: Self.key).flatMap(StartupProfile.init(rawValue:)) ?? .system
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

import Foundation
import ParallaxPlayback

/// Named AVKit buffering profiles for on-device startup-time A/B testing (Plan C).
/// `.fastStart` is the SHIPPING default, promoted from the 2026-07-08 device A/B
/// (Jellyfin over VPN: System 3152ms → Fast Start 1991ms; VLC control rows confirmed
/// the gap exceeds network jitter). `.system` stays pickable as the control.
/// A third candidate, "Fast Start (Eager)" (`automaticallyWaitsToMinimizeStalling =
/// false`), was DELETED in the same pass: it wedged the loading scrim forever (first
/// frame rendered, first `.playing` beat never landed) and measured no faster —
/// see the note in `StartupTuning`.
enum StartupProfile: String, CaseIterable, Sendable {
    case system
    case fastStart

    var tuning: StartupTuning {
        switch self {
        case .system:
            .systemDefault
        case .fastStart:
            StartupTuning(preferredForwardBufferSeconds: 3)
        }
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .fastStart: "Fast Start"
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

    /// The persisted profile, or `.fastStart` — the promoted shipping default — when
    /// nothing was ever picked (fresh install / release users) or the stored value no
    /// longer maps to a known case (e.g. a device that had the deleted Eager selected).
    var selected: StartupProfile {
        get {
            defaults.string(forKey: Self.key).flatMap(StartupProfile.init(rawValue:)) ?? .fastStart
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

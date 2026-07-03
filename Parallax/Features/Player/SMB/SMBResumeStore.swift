import Foundation
import CoreMedia
import ParallaxCore

/// Local resume positions for server-less (SMB) playback, keyed by `ItemID`.
/// UserDefaults-backed: positions are tiny, and the 500-entry LRU cap bounds growth.
/// Mirrors `ResumePolicy`'s rules: nothing below 5s (a misclick isn't progress),
/// cleared at ≥95% of a KNOWN duration (a finished film restarts from the top).
/// A nil/indefinite duration skips the 95% rule — an incomplete file's estimated
/// runtime must never wipe real progress.
///
/// An `actor` (not `@MainActor`): UserDefaults is thread-safe, the resolver calls in
/// from off-main, and the VM's beat handler fire-and-forgets writes into it.
actor SMBResumeStore {
    static let shared = SMBResumeStore()

    private let defaults: UserDefaults

    /// Storage shape: one dictionary under `smb.resume.v1`, entry per item —
    /// `["pos": seconds, "at": epochSeconds]`. `at` orders LRU eviction.
    private static let key = "smb.resume.v1"
    private static let maxEntries = 500
    private static let minimumProgressSeconds: Double = 5
    private static let completionFraction: Double = 0.95

    /// `defaults` is the test seam — `UserDefaults(suiteName:)` keeps test writes
    /// out of the real standard domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved resume offset, or nil when the item has none (never saved,
    /// cleared as finished, or evicted).
    func resumeTime(for id: ItemID) -> CMTime? {
        guard let seconds = entries()[id.rawValue]?["pos"], seconds > 0 else { return nil }
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Applies the resume rules: below the 5s floor → clear; at ≥95% of a known
    /// duration → clear (finished); otherwise write, evicting the oldest entries
    /// past the LRU cap.
    func save(position: CMTime, duration: CMTime?, for id: ItemID) {
        let seconds = CMTimeGetSeconds(position)
        guard seconds.isFinite, seconds >= Self.minimumProgressSeconds else {
            clear(id)
            return
        }
        if let duration, duration.isNumeric {
            let total = CMTimeGetSeconds(duration)
            if total > 0, seconds / total >= Self.completionFraction {
                clear(id)
                return
            }
        }
        var all = entries()
        all[id.rawValue] = ["pos": seconds, "at": Date.now.timeIntervalSince1970]
        if all.count > Self.maxEntries {
            let overflow = all.count - Self.maxEntries
            for (key, _) in all.sorted(by: { ($0.value["at"] ?? 0) < ($1.value["at"] ?? 0) }).prefix(overflow) {
                all.removeValue(forKey: key)
            }
        }
        defaults.set(all, forKey: Self.key)
    }

    func clear(_ id: ItemID) {
        var all = entries()
        guard all.removeValue(forKey: id.rawValue) != nil else { return }
        defaults.set(all, forKey: Self.key)
    }

    private func entries() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String: Double]] ?? [:]
    }
}

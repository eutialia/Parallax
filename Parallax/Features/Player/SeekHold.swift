import CoreMedia

/// Pins the DISPLAYED playback position at a committed seek target until the engine's
/// own clock arrives there.
///
/// A scrub A→B on a big transcode goes: commit → `reloadTranscode` → `.loading` scrim →
/// every engine beat dropped → the first beat of the new stream, seconds later. Without
/// a hold the bar reads `currentPosition`, which is still A for that whole window, so the
/// dot snaps back to A behind the scrim and jumps to B when playback resumes. The hold
/// makes the seek target the published position from the instant the commit starts, and
/// only yields once the engine agrees — one mechanism for touch, VoiceOver and tvOS,
/// replacing the iOS-only view-layer polling latch that never covered the Apple TV.
///
/// Pure value semantics so `SeekHoldTests` can pin the release rules without a player.
nonisolated struct SeekHold: Equatable, Sendable {
    /// How close the engine has to land before the hold yields. A keyframe-snapped
    /// transcode restart routinely misses the request by a second or two, so demanding
    /// exactness would strand the hold on every re-anchor; 3 s is the same tolerance
    /// `VLCKitEngine.seekHasSettled` uses and the old view-layer latch used.
    static let toleranceSeconds: Double = 3

    /// How many far-off TRANSPORT beats it takes to overrule the hold. `VLCKitEngine`'s
    /// settle fallback gives up after 10 polls and republishes the raw PRE-seek clock, so
    /// "the engine says A" is not by itself evidence the seek failed — the hold yields
    /// only once the engine has *insisted* on a far-off position across several playing/
    /// paused beats. At the shared 500 ms beat cadence that is ~4 s: long enough to ride
    /// out a reload, short enough that a genuinely wedged seek can never freeze the bar.
    static let staleBeatCeiling = 8

    /// What the caller should do with the beat it just absorbed.
    enum Verdict: Equatable, Sendable {
        /// Keep publishing the target; this beat's position is stale.
        case hold
        /// The engine owns the position from this beat on — drop the hold.
        case release
    }

    /// The committed seek destination — what the UI shows for as long as the hold lives.
    let target: CMTime
    /// Far-off transport beats seen so far; `staleBeatCeiling` of them ends the hold.
    private(set) var staleBeats = 0

    init(target: CMTime) {
        self.target = target
    }

    /// Judge one engine beat. ONLY a transport beat (`.playing`/`.paused` — the engine
    /// claiming a live clock) can end the hold; a `.buffering` beat is the engine saying
    /// "still fetching", which is evidence of nothing, so it neither releases nor spends
    /// the budget. The gate comes FIRST for a reason: `AVKitEngine.seek` yields a
    /// `.buffering(position: target)` echo BEFORE it awaits the real seek, so a drift check
    /// ahead of the gate released the hold on the commit's own echo — a no-op hold on every
    /// out-of-buffer in-stream seek, with the periodic observer free to publish transitional
    /// positions for the rest of the seek.
    mutating func absorb(position: CMTime, isTransportBeat: Bool) -> Verdict {
        guard isTransportBeat else { return .hold }
        let drift = abs(CMTimeGetSeconds(position) - CMTimeGetSeconds(target))
        // An invalid/indefinite CMTime makes `drift` NaN, which fails every comparison —
        // so it fell through as "far off" and quietly burned a beat of the budget.
        guard drift.isFinite else { return .hold }
        if drift <= Self.toleranceSeconds { return .release }
        staleBeats += 1
        return staleBeats >= Self.staleBeatCeiling ? .release : .hold
    }
}

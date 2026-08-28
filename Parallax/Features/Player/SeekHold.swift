import CoreMedia
import ParallaxPlayback

/// Pins the DISPLAYED playback position at a committed seek target until the engine says it
/// has actually resolved the seek.
///
/// A scrub A→B on a big transcode goes: commit → `reloadTranscode` → `.loading` scrim →
/// every engine beat dropped → the first beat of the new stream, seconds later. Without
/// a hold the bar reads `currentPosition`, which is still A for that whole window, so the
/// dot snaps back to A behind the scrim and jumps to B when playback resumes. The hold
/// makes the seek target the published position from the instant the commit starts, and
/// only yields once the engine agrees — one mechanism for touch, VoiceOver and tvOS,
/// replacing the iOS-only view-layer polling latch that never covered the Apple TV.
///
/// **It no longer guesses.** The engines carry the seek-settle contract (`PositionProvenance`):
/// every position-carrying beat says where its position came from — the engine's clock, its
/// forward estimate off the seek target, or a clock that hasn't republished at the new offset
/// yet. So the hold is one line of policy — believe the label — and the drift tolerance, the
/// stale-beat budget and the transport/buffering distinction that used to stand in for it are
/// gone. They were all attempts to infer, from position alone, the one fact the engine knew.
///
/// The hold answers only "who owns the published position", never "what may be drawn". A
/// `.projected` beat holds AND is display-safe, and splitting those two questions is the
/// caller's job (`PlayerViewModel.publish`) — which is why `Verdict` has two cases, not three.
///
/// Pure value semantics so `SeekHoldTests` can pin the release rules without a player.
nonisolated struct SeekHold: Equatable, Sendable {
    /// Anti-wedge floor, and nothing else: an engine that never reports an observed clock
    /// again — a seek that died, a session whose poll loop stopped — must not freeze the bar
    /// forever.
    /// A healthy session never reaches it. Sized above `reloadResolveDeadline` (15 s), which
    /// bounds the slowest healthy hold there is: a re-anchor that spends its entire re-resolve
    /// budget before the new stream even starts loading. If this ever fires on a working
    /// session, the number is wrong — not the engine.
    static let watchdog: Duration = .seconds(20)

    /// What the caller should do with the beat it just absorbed.
    enum Verdict: Equatable, Sendable {
        /// Keep publishing the target; this beat's position is the engine's guess.
        case hold
        /// The engine owns the position from this beat on — drop the hold.
        case release
    }

    /// The committed seek destination — what the UI shows for as long as the hold lives.
    let target: CMTime
    /// When the commit armed this hold, for the watchdog. A re-scrub builds a new hold, so
    /// the newest commit always gets the full budget.
    let armedAt: ContinuousClock.Instant

    init(target: CMTime, armedAt: ContinuousClock.Instant = .now) {
        self.target = target
        self.armedAt = armedAt
    }

    /// Judge one engine beat. It takes the beat's LABEL and nothing else — no position: the
    /// engine already decided the only question this type asks, and re-deriving it from drift
    /// is what the tolerance and the stale-beat budget used to do wrong.
    ///
    /// `.observed` releases, because it is the engine's clock with no seek of its own
    /// outstanding — even when it landed nowhere near the request. AVKit's landing is only
    /// segment-accurate, and a VLC hold that gave up republishes whatever the clock really
    /// reads; pinning the bar at an unreachable target over video that is demonstrably playing
    /// elsewhere is the worse lie. `.projected` and `.stale` both hold: neither is evidence the
    /// seek resolved, and that is the only question this type answers.
    ///
    /// The watchdog is the only other exit, and it must never be the one a real session takes.
    /// One case makes that worth spelling out: a VLC seek committed while PAUSED keeps
    /// projecting until playback resumes, so a user who scrubs, pauses and walks away can hold
    /// legitimately for minutes and trip it. On a `.projected` beat that release costs nothing —
    /// the beat carries the held target (VLC's extrapolation freezes there, which IS the correct
    /// paused position), so nothing on screen moves.
    ///
    /// On a `.stale` beat it costs everything, and the difference is not this type's to make.
    /// The watchdog releases on whatever beat happens to arrive, and `.stale` is the pre-seek
    /// clock: adopting it is the snap-back the hold exists to prevent, performed by the exit
    /// itself. So `.release` means only "the hold is over" — never "publish this position".
    /// Splitting those is the caller's job, and `PlayerViewModel.publish` drops a `.stale`
    /// position on release for exactly this reason.
    func absorb(provenance: PositionProvenance, now: ContinuousClock.Instant) -> Verdict {
        if provenance == .observed { return .release }
        return now - armedAt >= Self.watchdog ? .release : .hold
    }
}

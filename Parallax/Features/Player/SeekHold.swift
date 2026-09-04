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
/// It is the release POLICY and nothing else. What the window means — the origin the crossing
/// runs from, the identity a re-scrub supersedes, the stage the bar draws — belongs to
/// `SeekFlight`, which lives and dies with it.
///
/// Pure value semantics so `SeekHoldTests` can pin the release rules without a player.
nonisolated struct SeekHold: Equatable, Sendable {
    /// Anti-wedge floor, and nothing else: an engine that never reports an observed clock
    /// again — a seek that died, a session whose poll loop stopped — must not freeze the bar
    /// forever.
    ///
    /// It is a SILENCE budget, spent by `PlayerViewModel`'s watchdog task and not by this type:
    /// armed when a hold is set, restarted by every beat the live engine delivers while it
    /// stands, so it fires only after this long with no beat at all. Both engines are
    /// beat-on-motion (VLC's poll is `isPlaying`-gated, AVKit's clock is a periodic observer),
    /// so a seek into an unbuffered region on a dead link produces one `.buffering` beat and
    /// then silence — and a deadline that can only be checked when a beat arrives is exactly
    /// the deadline that never fires in the case it exists for.
    ///
    /// A healthy session never reaches it. Sized above `reloadResolveDeadline` (15 s), the
    /// longest a healthy re-anchor goes without a beat: the re-resolve runs with the old
    /// session closed and the new one not yet loading. If this ever fires on a working
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

    init(target: CMTime) {
        self.target = target
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
    /// The watchdog is the only other exit and it does not come through here — see `watchdog`.
    /// So this stays a total function of the label: `.release` means "the engine owns the
    /// position from this beat on", and it is the only release that ever carries a position.
    func absorb(provenance: PositionProvenance) -> Verdict {
        provenance == .observed ? .release : .hold
    }
}

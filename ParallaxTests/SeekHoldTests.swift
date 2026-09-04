import CoreMedia
import ParallaxPlayback
import Testing
@testable import Parallax

/// `SeekHold` is the pure core of the seek-hold fix: given a committed seek target and the
/// engine's beats, decide when the engine gets the published position back. Since the
/// seek-settle contract landed (`PositionProvenance`), that decision is no longer a heuristic —
/// the engine labels every beat, and the hold just obeys the label. Everything below runs
/// without a player, an engine, or a real clock.
///
/// One axis the hold deliberately does NOT have: display-safety. `.projected` and `.stale`
/// both hold, and whether the beat may be drawn is the view model's call — see
/// `PlayerViewModelTests`' hold suite.
///
/// The anti-wedge watchdog is not an axis here either. It fires on elapsed time with no beat
/// at all — the windows it exists for are the ones where beats stop arriving — so it is a task
/// in `PlayerViewModel` and it is tested there. The only thing left of it in this file is the
/// constant's size.
@Suite("SeekHold — the committed seek target's grip on the published position")
struct SeekHoldTests {

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private static let target = time(3_000)

    private static func hold() -> SeekHold {
        SeekHold(target: target)
    }

    /// The whole rule. Neither non-observed provenance is evidence about where the media is:
    /// `.projected` is the engine guessing forward off its own target, `.stale` is the engine's
    /// clock still reading the pre-seek position — so both hold. `.observed` is the engine's own
    /// clock with no seek outstanding, so it releases even when it landed nowhere near the
    /// request: AVKit's landing is only segment-accurate and a VLC hold that gave up republishes
    /// a clamped position, and pinning the bar at an unreachable target over video that is
    /// demonstrably playing elsewhere is the worse lie.
    ///
    /// Two axes the old heuristic had are simply GONE from the signature, which is the point:
    /// `absorb` sees no position (the old drift tolerance) and no beat kind (the old
    /// transport-vs-buffering gate). `.playing`, `.paused` and `.buffering` are judged by the
    /// same label at any distance; the VM-level suite covers all three arriving for real.
    @Test("the verdict is the label, and nothing else",
          arguments: [(PositionProvenance.projected, SeekHold.Verdict.hold),
                      (.stale, .hold),
                      (.observed, .release)])
    func theVerdictIsTheLabel(provenance: PositionProvenance, expected: SeekHold.Verdict) {
        #expect(Self.hold().absorb(provenance: provenance) == expected)
    }

    /// Bounded clear of every silent stretch a healthy session has: a stream open, which the
    /// engine's load watchdog ends at 30 s by failing the session, and a re-anchor's re-resolve
    /// (`reloadResolveDeadline`, 15 s). The watchdog must never be what ends either.
    @Test("the watchdog outlives the slowest healthy stream open and re-anchor")
    func watchdogClearsTheEngineDeadlines() {
        #expect(SeekHold.watchdog > .seconds(30))
    }

    /// The hold is the release POLICY and nothing else: the commit's origin, its identity and
    /// its stage all belong to `SeekFlight`. What is left here is the target.
    @Test("value semantics: the target is the whole identity")
    func equality() {
        #expect(Self.hold() == Self.hold())
        #expect(Self.hold() != SeekHold(target: Self.time(4_000)))
    }
}

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
@Suite("SeekHold — the committed seek target's grip on the published position")
struct SeekHoldTests {

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private static let target = time(3_000)
    private static let armedAt = ContinuousClock.now

    private static func hold(armedAt: ContinuousClock.Instant = SeekHoldTests.armedAt) -> SeekHold {
        SeekHold(target: target, armedAt: armedAt)
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
        let hold = Self.hold()
        #expect(hold.absorb(provenance: provenance,
                            now: Self.armedAt.advanced(by: .seconds(1))) == expected)
    }

    /// The anti-wedge floor, and nothing more: an engine that never reports an observed clock
    /// again (a dead seek, a crashed session) must not freeze the bar forever. It is not a
    /// timeout on the seek — a healthy session never reaches it.
    @Test("the watchdog releases a held-open hold, and not one instant early", arguments: [
        ("armed", Duration.zero, SeekHold.Verdict.hold),
        ("mid-flight", .seconds(5), .hold),
        ("past the reload resolve deadline", .seconds(15), .hold),
        ("a millisecond short of the watchdog", SeekHold.watchdog - .milliseconds(1), .hold),
        ("exactly the watchdog", SeekHold.watchdog, .release),
        ("long past it", SeekHold.watchdog + .seconds(60), .release),
    ] as [(String, Duration, SeekHold.Verdict)])
    func watchdogReleasesAWedgedHold(label: String, elapsed: Duration, expected: SeekHold.Verdict) {
        let hold = Self.hold()
        #expect(hold.absorb(provenance: .stale, now: Self.armedAt.advanced(by: elapsed)) == expected, "\(label)")
    }

    /// A paused VLC seek keeps projecting until playback resumes (the extrapolation freezes on
    /// the target, which IS the correct paused position), so the watchdog can legitimately
    /// fire on a user who paused mid-scrub and walked away. Harmless: the beat it releases on
    /// carries the held target anyway, so the bar does not move.
    @Test("the watchdog fires on a legitimately-parked paused seek — and releases onto the target")
    func watchdogOnAPausedHoldReleasesOntoTheTarget() {
        let hold = Self.hold()
        #expect(hold.absorb(provenance: .projected, now: Self.armedAt.advanced(by: SeekHold.watchdog)) == .release)
    }

    /// Re-scrubbing during a hold builds a NEW hold, which restarts the watchdog: the second
    /// commit gets the full budget, not whatever the first one had left.
    @Test("a re-arm resets the watchdog clock")
    func reArmResetsTheWatchdog() {
        let first = Self.hold()
        let reArmedAt = Self.armedAt.advanced(by: SeekHold.watchdog - .seconds(1))
        let second = SeekHold(target: Self.time(4_000), armedAt: reArmedAt)

        let now = reArmedAt.advanced(by: .seconds(2))   // past the FIRST hold's deadline
        #expect(first.absorb(provenance: .stale, now: now) == .release)
        #expect(second.absorb(provenance: .stale, now: now) == .hold)
    }

    /// Bounded well clear of `reloadResolveDeadline` (15 s): a re-anchor that spends its whole
    /// resolve budget and then loads is the longest hold a healthy session produces, and the
    /// watchdog must never be what ends it.
    @Test("the watchdog outlives the slowest healthy re-anchor")
    func watchdogClearsTheReloadResolveDeadline() {
        #expect(SeekHold.watchdog > .seconds(15))
    }

    /// The hold is the release POLICY and nothing else: the commit's origin, its identity and
    /// its stage all belong to `SeekFlight`. What is left here is a target and a deadline.
    @Test("value semantics: the target and the arming instant are the whole identity")
    func equality() {
        #expect(Self.hold() == Self.hold())
        #expect(Self.hold() != SeekHold(target: Self.time(4_000), armedAt: Self.armedAt))
        #expect(Self.hold() != Self.hold(armedAt: Self.armedAt.advanced(by: .seconds(1))))
    }
}

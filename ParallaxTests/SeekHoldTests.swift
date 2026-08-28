import CoreMedia
import Testing
@testable import Parallax

/// `SeekHold` is the pure core of the seek-hold fix: given a committed seek target and the
/// engine's beats, decide when the engine gets the position back. Every rule below is
/// exercised without a player, an engine, or a clock.
@Suite("SeekHold — the committed seek target's grip on the published position")
struct SeekHoldTests {

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private static let target = time(3_000)

    /// Both signs of the drift, and the boundary itself: a keyframe-snapped landing is
    /// the engine agreeing, not a stale beat, so `toleranceSeconds` is INCLUSIVE.
    @Test("a beat within tolerance releases immediately, on either side and exactly at the boundary",
          arguments: [3_000.0, 3_002.9, 3_003.0, 2_997.0, 2_999.5])
    func withinToleranceReleases(seconds: Double) {
        var hold = SeekHold(target: Self.target)
        #expect(hold.absorb(position: Self.time(seconds), isTransportBeat: true) == .release)
        #expect(hold.staleBeats == 0)
    }

    /// Only a TRANSPORT beat can end the hold — including one that lands ON the target.
    /// `AVKitEngine.seek` yields a `.buffering(position: target)` echo BEFORE it awaits the
    /// real seek, so a near buffering beat is the engine restating the request, not the
    /// engine arriving: releasing on it would make the hold a no-op on every out-of-buffer
    /// in-stream seek and hand the bar back to the periodic observer mid-seek.
    @Test("a buffering beat near the target still HOLDS — the pre-seek echo is not an arrival",
          arguments: [3_000.0, 3_001.0, 2_999.0])
    func withinToleranceBufferingHolds(seconds: Double) {
        var hold = SeekHold(target: Self.target)
        #expect(hold.absorb(position: Self.time(seconds), isTransportBeat: false) == .hold)
        #expect(hold.staleBeats == 0)
    }

    /// An engine can publish an invalid/indefinite CMTime (AVPlayer before the item's
    /// duration resolves, VLC between media). `abs(NaN - x)` is NaN, which fails every
    /// comparison — pre-guard that read as "far off" and quietly burned the budget.
    @Test("a non-finite position is not evidence of anything: hold, and spend no budget",
          arguments: [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity, CMTime.negativeInfinity])
    func nonFinitePositionsHoldWithoutCounting(position: CMTime) {
        var hold = SeekHold(target: Self.target)
        #expect(hold.absorb(position: position, isTransportBeat: true) == .hold)
        #expect(hold.staleBeats == 0)
        #expect(hold.absorb(position: position, isTransportBeat: false) == .hold)
        #expect(hold.staleBeats == 0)
    }

    /// The re-anchor window: the reload's scrim is up and every beat still carries the
    /// pre-seek clock. Those are never evidence the target is wrong, so they must not
    /// spend the budget — however many arrive.
    @Test("far-off buffering beats hold forever and never count")
    func bufferingBeatsHoldWithoutCounting() {
        var hold = SeekHold(target: Self.target)
        for _ in 0..<(SeekHold.staleBeatCeiling * 3) {
            #expect(hold.absorb(position: Self.time(600), isTransportBeat: false) == .hold)
        }
        #expect(hold.staleBeats == 0)
    }

    /// The wedge escape: VLC's settle fallback gives up after 10 polls and republishes the
    /// raw pre-seek clock as ordinary transport beats. The hold must yield rather than
    /// freeze the bar — but only after the engine has insisted `staleBeatCeiling` times.
    @Test("far-off transport beats hold until the ceiling beat, which releases — stale either side of the target",
          arguments: [600.0, 6_000.0])
    func transportBeatsHoldUntilCeiling(stale: Double) {
        var hold = SeekHold(target: Self.target)
        for beat in 1..<SeekHold.staleBeatCeiling {
            #expect(hold.absorb(position: Self.time(stale), isTransportBeat: true) == .hold)
            #expect(hold.staleBeats == beat)
        }
        #expect(hold.absorb(position: Self.time(stale), isTransportBeat: true) == .release)
        #expect(hold.staleBeats == SeekHold.staleBeatCeiling)
    }

    @Test("a mix: interleaved buffering beats neither reset nor advance the transport count")
    func bufferingBeatsDoNotDisturbTheCount() {
        var hold = SeekHold(target: Self.target)
        for _ in 1..<SeekHold.staleBeatCeiling {
            #expect(hold.absorb(position: Self.time(600), isTransportBeat: true) == .hold)
            #expect(hold.absorb(position: Self.time(600), isTransportBeat: false) == .hold)
            #expect(hold.absorb(position: Self.time(601), isTransportBeat: false) == .hold)
        }
        #expect(hold.staleBeats == SeekHold.staleBeatCeiling - 1)
        // The next TRANSPORT beat is the ceiling — the buffering ones bought no ground.
        #expect(hold.absorb(position: Self.time(600), isTransportBeat: true) == .release)
    }

    @Test("a near beat arriving before the ceiling releases and leaves the count where it was")
    func nearBeatShortCircuitsTheCount() {
        var hold = SeekHold(target: Self.target)
        #expect(hold.absorb(position: Self.time(600), isTransportBeat: true) == .hold)
        #expect(hold.absorb(position: Self.time(3_001), isTransportBeat: true) == .release)
        #expect(hold.staleBeats == 1)
    }

    @Test("value semantics: equal targets and equal stale counts compare equal, a spent beat does not")
    func equality() {
        let fresh = SeekHold(target: Self.target)
        #expect(fresh == SeekHold(target: Self.target))
        #expect(fresh != SeekHold(target: Self.time(4_000)))

        var spent = SeekHold(target: Self.target)
        #expect(spent.absorb(position: Self.time(600), isTransportBeat: true) == .hold)
        #expect(spent != fresh)

        // A copy taken before the beat is untouched by it — the hold is a value, so the
        // view model's `seekHold = hold` write-back is what carries the count forward.
        var copy = fresh
        #expect(copy.absorb(position: Self.time(600), isTransportBeat: true) == .hold)
        #expect(copy == spent)
        #expect(fresh.staleBeats == 0)
    }
}

import Foundation
import Testing
import ParallaxCore
import ParallaxPlayback

/// `ReactiveFallback.shouldReroute` is a pure 4-axis decision (engine, container,
/// already-rerouted, error) — exercised as the decision matrix it is, plus the
/// exhaustive `Container.allCases` sweep so a new container added to ParallaxCore can't
/// silently join the MP4-family eligible set without a matrix entry here.
@Suite("ReactiveFallback routing")
struct ReactiveFallbackTests {

    /// Rows that add an axis the `Container.allCases` sweep below doesn't already cover
    /// (which fixes engine=avKit, alreadyRerouted=false, error=.assetNotPlayable and
    /// sweeps every container): the engine axis, the already-rerouted axis, and the
    /// error-kind axis. The positive "avKit + mp4/mov + .assetNotPlayable reroutes" case
    /// is the sweep's own mp4/mov rows — repeating it here would be redundant.
    @Test(
        "every non-container axis that can veto a reroute",
        arguments: [
            // (currentEngine, container, alreadyRerouted, error, expected)
            (PlaybackEngineID.vlcKit, Container.mp4, false, PlaybackError.assetNotPlayable, false),   // a VLC failure is already the fallback
            (PlaybackEngineID.avKit, Container.mp4, true, PlaybackError.assetNotPlayable, false),      // second failure — one shot only
            (PlaybackEngineID.avKit, Container.mp4, false, PlaybackError.networkStalled, false),       // a link stall, not a decode defect — rerouting would mask the honest stall scrim
            (PlaybackEngineID.avKit, Container.mp4, false, PlaybackError.unknown("x"), false),         // an engine-specific failure outside the two known cases
            (PlaybackEngineID.avKit, Container.mp4, false, PlaybackError.loadTimedOut, true),          // the load watchdog: a VLC retry is bounded and sometimes rescues a file AVKit hangs on
            (PlaybackEngineID.avKit, Container.mkv, false, PlaybackError.loadTimedOut, false),         // …still MP4-family only
        ]
    )
    func decisionMatrix(
        currentEngine: PlaybackEngineID,
        container: Container,
        alreadyRerouted: Bool,
        error: PlaybackError,
        expected: Bool
    ) {
        #expect(ReactiveFallback.shouldReroute(
            currentEngine: currentEngine,
            container: container,
            alreadyRerouted: alreadyRerouted,
            error: error
        ) == expected)
    }

    /// Exhaustive over every `Container` ParallaxCore declares — a new MP4-adjacent
    /// container added there must earn an explicit yes/no here, not fall through by
    /// default. Fixes every other axis to its most-favorable value (AVKit, first
    /// failure, `.assetNotPlayable`) so this is a pure container sweep.
    @Test("only mp4/mov are eligible containers, exhaustively", arguments: Container.allCases)
    func onlyMP4FamilyIsEligible(container: Container) {
        let expected = container == .mp4 || container == .mov
        #expect(ReactiveFallback.shouldReroute(
            currentEngine: .avKit,
            container: container,
            alreadyRerouted: false,
            error: .assetNotPlayable
        ) == expected)
    }
}

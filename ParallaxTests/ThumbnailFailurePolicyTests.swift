import Foundation
import Testing
import ParallaxPlayback
@testable import Parallax

/// The frame-grab POISON rule, on its own. A recorded failure silences a file for hours (exponential
/// backoff, capped at 24h), so the cut between "this file is broken" and "the network blipped / we
/// gave up" is worth pinning without a share, a bridge or a decode in the way — it was previously an
/// inline condition inside a `catch` that only an end-to-end run could reach.
@Suite("Thumbnail failure policy")
struct ThumbnailFailurePolicyTests {

    struct PoisonCase: Sendable, CustomTestStringConvertible {
        let name: String
        let error: any Error & Sendable
        let hadTransportFault: Bool
        let records: Bool
        var testDescription: String { name }

        init(_ name: String, error: any Error & Sendable, hadTransportFault: Bool, records: Bool) {
            self.name = name
            self.error = error
            self.hadTransportFault = hadTransportFault
            self.records = records
        }
    }

    static let poisonCases: [PoisonCase] = [
        .init("a transport fault never blames the file",
              error: VLCThumbnailError.timedOut, hadTransportFault: true, records: false),
        .init("cancellation never blames the file",
              error: CancellationError(), hadTransportFault: false, records: false),
        .init("cancellation during a transport fault still doesn't",
              error: CancellationError(), hadTransportFault: true, records: false),
        // One content case is enough: the rule reads the error only for `CancellationError`, so
        // every other type — VLC's, AV's, timeout or encode — lands on the same branch.
        .init("a content-level failure on a healthy link is the file's fault",
              error: VLCThumbnailError.encodingFailed, hadTransportFault: false, records: true),
    ]

    @Test("only a content-level failure on a healthy link poisons the key", arguments: poisonCases)
    func poisonDecision(_ testCase: PoisonCase) {
        #expect(
            MediaArtworkProvider.shouldRecordFailure(
                error: testCase.error, hadTransportFault: testCase.hadTransportFault
            ) == testCase.records
        )
    }

    /// Probe-stage transport evidence is sampled off the discarded probe reader and ORed with
    /// the frame-grab session's flag. A nil-probe path that already saw ECONNRESET (or similar)
    /// must still feed `.transportFailure` / refuse poison even when the FRESH grab session
    /// itself is clean — pin the OR so neither side can be dropped silently.
    struct TransportComposeCase: Sendable, CustomTestStringConvertible {
        let name: String
        let session: Bool
        let probe: Bool
        let expected: Bool
        var testDescription: String { name }
    }

    static let transportComposeCases: [TransportComposeCase] = [
        TransportComposeCase(name: "neither", session: false, probe: false, expected: false),
        TransportComposeCase(name: "session only", session: true, probe: false, expected: true),
        TransportComposeCase(name: "probe stage only (discarded reader)", session: false, probe: true, expected: true),
        TransportComposeCase(name: "both", session: true, probe: true, expected: true),
    ]

    @Test("probe-stage transport evidence ORs with the session flag", arguments: transportComposeCases)
    func transportCompose(_ testCase: TransportComposeCase) {
        let composed = MediaArtworkProvider.effectiveTransportFault(
            sessionHadTransportFault: testCase.session, probeTransportFault: testCase.probe)
        #expect(composed == testCase.expected)
        // And the poison guard sees the composed bit: any transport evidence — from either side —
        // must refuse to blacklist the file; only the "neither" case still poisons.
        #expect(
            MediaArtworkProvider.shouldRecordFailure(
                error: VLCThumbnailError.encodingFailed, hadTransportFault: composed
            ) == !testCase.expected
        )
    }

    /// `frameGrab`'s early exit (the bridge's own `session.start()` throwing before any decode ran)
    /// still owes `.transportFailure` when the nil-probe branch already captured evidence off the
    /// discarded probe reader — pins the THREADING of that sticky bit into the early-exit outcome,
    /// not just the OR inside `effectiveTransportFault`. A call site that silently drops
    /// `probeTransportFault` (e.g. hardcodes `false`) would make this fail.
    @Test("a nil-probe's sticky transport fault still wins the early bridge-start-failure exit",
          arguments: [(probe: false, expectTransportFailure: false), (probe: true, expectTransportFailure: true)])
    func earlyExitOutcomeThreadsProbeFault(_ testCase: (probe: Bool, expectTransportFailure: Bool)) {
        switch MediaArtworkProvider.earlyExitOutcome(probeTransportFault: testCase.probe) {
        case .transportFailure:
            #expect(testCase.expectTransportFailure)
        case .inconclusive:
            #expect(!testCase.expectTransportFailure)
        case .success:
            Issue.record("early exit must never report .success — nothing decoded")
        }
    }
}

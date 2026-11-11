import Foundation
import Testing
import ParallaxTestScaling
import ParallaxPlayback
@testable import ParallaxFeatures

/// The frame-grab POISON rule, on its own. A recorded failure silences a file for hours (exponential
/// backoff, capped at 24h), so the cut between "this file is broken" and "the network blipped / we
/// gave up" is worth pinning without a share, a bridge or a decode in the way — it was previously an
/// inline condition inside a `catch` that only an end-to-end run could reach.
@Suite("Thumbnail failure policy", .scaledTimeLimit())
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
              error: AVThumbnailError.timedOut, hadTransportFault: true, records: false),
        .init("cancellation never blames the file",
              error: CancellationError(), hadTransportFault: false, records: false),
        .init("cancellation during a transport fault still doesn't",
              error: CancellationError(), hadTransportFault: true, records: false),
        // One content case is enough: the rule reads the error only for `CancellationError`, so
        // every other type, timeout or encode, lands on the same branch.
        .init("a content-level failure on a healthy link is the file's fault",
              error: AVThumbnailError.encodingFailed, hadTransportFault: false, records: true),
    ]

    @Test("only a content-level failure on a healthy link poisons the key", arguments: poisonCases)
    func poisonDecision(_ testCase: PoisonCase) {
        #expect(
            MediaArtworkProvider.shouldRecordFailure(
                error: testCase.error, hadTransportFault: testCase.hadTransportFault
            ) == testCase.records
        )
    }

    /// The nil-probe exit owes `.transportFailure` when the abandoned probe reader already saw a
    /// link fault, and nothing otherwise.
    @Test("a nil probe's sticky transport fault decides its early exit",
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

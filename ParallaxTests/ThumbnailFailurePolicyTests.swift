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
        let error: any Error
        let hadTransportFault: Bool
        let records: Bool
        var testDescription: String { name }

        init(_ name: String, error: any Error, hadTransportFault: Bool, records: Bool) {
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
}

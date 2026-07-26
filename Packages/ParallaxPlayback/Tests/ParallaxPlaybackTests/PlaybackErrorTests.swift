import Foundation
import Testing
import ParallaxPlayback

/// `PlaybackError`'s `==` is hand-written, not synthesized — and the player's view model
/// leans on it to de-duplicate terminal reporting (an engine may emit `.failed` and then
/// have `teardown()` finish the stream separately). A case the operator forgot would
/// either drop a real failure or re-report one.
@Suite("PlaybackError equality")
struct PlaybackErrorTests {

    @Test("matching cases compare equal", arguments: [
        PlaybackError.assetNotPlayable,
        .networkStalled,
        .unknown("boom"),
        .unknown(""),
    ])
    func sameCaseIsEqual(error: PlaybackError) {
        #expect(error == error)
    }

    @Test("different cases never compare equal", arguments: [
        (PlaybackError.assetNotPlayable, PlaybackError.networkStalled),
        (.assetNotPlayable, .unknown("boom")),
        (.networkStalled, .unknown("boom")),
        (.networkStalled, .assetNotPlayable),
        (.unknown("boom"), .assetNotPlayable),
    ] as [(PlaybackError, PlaybackError)])
    func differentCasesAreUnequal(lhs: PlaybackError, rhs: PlaybackError) {
        #expect(lhs != rhs)
    }

    /// The payload is a log-safe summary, so two *different* engine failures must not
    /// collapse into one just because they share a case.
    @Test("the unknown payload participates in equality")
    func unknownComparesItsPayload() {
        #expect(PlaybackError.unknown("boom") == .unknown("boom"))
        #expect(PlaybackError.unknown("boom") != .unknown("bang"))
        #expect(PlaybackError.unknown("boom") != .unknown("BOOM"))
    }
}

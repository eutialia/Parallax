import Foundation
import Testing
import ParallaxPlayback

/// Equality is synthesized. What is worth pinning is the part synthesis makes a *choice*
/// about and the player leans on: the `.unknown` payload participates, so two different
/// engine failures never collapse into one — the view model de-duplicates terminal
/// reporting by comparing these (an engine may emit `.failed` and then have `teardown()`
/// finish the stream separately).
@Suite("PlaybackError equality")
struct PlaybackErrorTests {

    @Test("the unknown payload participates in equality")
    func unknownComparesItsPayload() {
        #expect(PlaybackError.unknown("boom") == .unknown("boom"))
        #expect(PlaybackError.unknown("boom") != .unknown("bang"))
        #expect(PlaybackError.unknown("boom") != .unknown("BOOM"))
    }

    @Test("a payload-free case never equals another")
    func distinctCasesAreUnequal() {
        #expect(PlaybackError.assetNotPlayable != .networkStalled)
        #expect(PlaybackError.networkStalled != .unknown("boom"))
    }
}

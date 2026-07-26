import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("UserItemData")
struct UserItemDataTests {
    @Test("the played fraction divides the position by the runtime ticks", arguments: [
        (LibraryFixtures.ticks(seconds: 25), LibraryFixtures.ticks(seconds: 100), 0.25),
        (LibraryFixtures.ticks(seconds: 100), LibraryFixtures.ticks(seconds: 100), 1.0),
        (0, LibraryFixtures.ticks(seconds: 100), 0.0),
    ])
    func playedFractionFromTicks(position: Int64, runtime: Int64, expected: Double) {
        let data = LibraryFixtures.userData(positionTicks: position)
        #expect(data.playedFraction(runtimeTicks: runtime) == expected)
    }

    /// Nothing to divide by: an unknown or zero runtime must yield nil rather than an infinity
    /// or a divide-by-zero trap.
    @Test("no fraction without a positive runtime", arguments: [nil, 0, -1] as [Int64?])
    func playedFractionNeedsARuntime(runtime: Int64?) {
        let data = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 25))
        #expect(data.playedFraction(runtimeTicks: runtime) == nil)
    }

    @Test("the Duration overload converts seconds into ticks before dividing")
    func playedFractionFromDuration() {
        let data = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 30))
        #expect(data.playedFraction(runtime: .seconds(120)) == 0.25)
    }

    /// Unstarted is distinct from 0% — a tile with no progress bar at all, not an empty one.
    @Test("an unstarted item has no fraction, even with a known runtime")
    func playedFractionUnstarted() {
        #expect(LibraryFixtures.userData().playedFraction(runtime: .seconds(120)) == nil)
    }

    @Test("the Duration overload still needs a runtime")
    func playedFractionDurationNeedsRuntime() {
        let data = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 30))
        #expect(data.playedFraction(runtime: nil) == nil)
    }

    /// Remaining minutes round UP: with 61 seconds left the caption must read "2 min left",
    /// never "1 min left" followed by a minute of silence.
    @Test("remaining minutes round up to the next whole minute", arguments: [
        (LibraryFixtures.ticks(minutes: 23), 45 * 60, 22),
        (LibraryFixtures.ticks(seconds: 2699), 45 * 60, 1),    // 1s left → still a minute
        (LibraryFixtures.ticks(seconds: 2639), 45 * 60, 2),    // 61s left → two
        (0, 45 * 60, 45),
    ])
    func remainingMinutes(position: Int64, runtimeSeconds: Int, expected: Int) {
        let data = LibraryFixtures.userData(positionTicks: position)
        #expect(data.remainingMinutes(runtime: .seconds(runtimeSeconds)) == expected)
    }

    @Test("a finished or over-run position reports no time left rather than a negative one")
    func remainingMinutesClampsAtZero() {
        let atEnd = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 2700))
        #expect(atEnd.remainingMinutes(runtime: .seconds(2700)) == nil)

        let overrun = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 9999))
        #expect(overrun.remainingMinutes(runtime: .seconds(2700)) == nil)
    }

    @Test("remaining minutes need a positive runtime", arguments: [nil, 0] as [Int?])
    func remainingMinutesNeedsRuntime(runtimeSeconds: Int?) {
        let data = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(minutes: 5))
        #expect(data.remainingMinutes(runtime: runtimeSeconds.map { .seconds($0) }) == nil)
    }

    /// The single canonical "show a Resume affordance" test — stated here rather than
    /// re-derived at each call site, because progress alone can't express it.
    @Test("in-progress means started AND not finished", arguments: [
        (false, Int64(0), false),                                  // untouched
        (false, LibraryFixtures.ticks(minutes: 5), true),          // mid-watch
        (true, LibraryFixtures.ticks(minutes: 5), false),          // played, stale ticks left over
        (true, Int64(0), false),                                   // played cleanly
    ])
    func isInProgress(played: Bool, position: Int64, expected: Bool) {
        #expect(LibraryFixtures.userData(played: played, positionTicks: position).isInProgress == expected)
    }

    @Test("withFavorite changes the favorite flag and nothing else")
    func withFavorite() {
        let original = LibraryFixtures.userData(
            played: true, positionTicks: 42, playCount: 3, lastPlayedDate: Date(timeIntervalSince1970: 100)
        )

        let favorited = original.withFavorite(true)
        #expect(favorited.isFavorite)
        #expect(favorited.played == original.played)
        #expect(favorited.playbackPositionTicks == original.playbackPositionTicks)
        #expect(favorited.playCount == original.playCount)
        #expect(favorited.lastPlayedDate == original.lastPlayedDate)
        #expect(favorited.withFavorite(false) == original)
    }

    /// A played-operation response's `isFavorite` is a DTO-boundary default (an absent field
    /// mapped to false), not real state, so it must never overwrite the existing flag.
    @Test("withPlayed adopts the played-owned fields but keeps the local favorite flag")
    func withPlayedKeepsFavorite() {
        let local = LibraryFixtures.userData(isFavorite: true)
        let payload = LibraryFixtures.userData(
            played: true, positionTicks: 999, playCount: 4, isFavorite: false,
            lastPlayedDate: Date(timeIntervalSince1970: 500)
        )

        let merged = local.withPlayed(from: payload)
        #expect(merged.isFavorite, "a played response must not clear a favorite")
        #expect(merged.played)
        #expect(merged.playbackPositionTicks == 999)
        #expect(merged.playCount == 4)
    }

    /// `lastPlayedDate` IS played-owned: Continue Watching orders on it, so keeping the stale
    /// date would sort a freshly watched item to the wrong place.
    @Test("withPlayed adopts the payload's last-played date")
    func withPlayedAdoptsLastPlayedDate() {
        let stale = Date(timeIntervalSince1970: 100)
        let fresh = Date(timeIntervalSince1970: 900)
        let local = LibraryFixtures.userData(lastPlayedDate: stale)
        let payload = LibraryFixtures.userData(played: true, lastPlayedDate: fresh)

        #expect(local.withPlayed(from: payload).lastPlayedDate == fresh)
    }

    @Test("withPlayed clears the date when the payload has none (an unwatch)")
    func withPlayedClearsLastPlayedDate() {
        let local = LibraryFixtures.userData(played: true, lastPlayedDate: Date(timeIntervalSince1970: 100))
        let payload = LibraryFixtures.userData(played: false, lastPlayedDate: nil)

        #expect(local.withPlayed(from: payload).lastPlayedDate == nil)
        #expect(local.withPlayed(from: payload).played == false)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        try assertCodableRoundTrip(LibraryFixtures.userData(
            played: true, positionTicks: 42, playCount: 3, isFavorite: true,
            lastPlayedDate: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }
}

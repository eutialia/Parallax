import Foundation
@testable import Parallax
@testable import ParallaxJellyfin

/// Records every progress beat the VM forwards, in order, so tests assert the
/// start/progress/stopped cadence, the tick values, and the item id.
actor StubPlaybackReporting: PlaybackReporting {
    enum Event: Equatable {
        case start(ticks: Int, isPaused: Bool, itemID: String)
        case progress(ticks: Int, isPaused: Bool, itemID: String)
        case stopped(ticks: Int, itemID: String)
    }

    private(set) var events: [Event] = []
    /// Encoding kills and keepalive pings land in their own lists (not
    /// `events`) so the existing exact-sequence cadence assertions stay
    /// focused on the report beats.
    private(set) var stoppedEncodings: [String] = []
    private(set) var pings: [String] = []

    func reportStart(_ beat: ProgressBeat) async {
        events.append(.start(ticks: beat.positionTicks, isPaused: beat.isPaused, itemID: beat.itemID))
    }

    func reportProgress(_ beat: ProgressBeat) async {
        events.append(.progress(ticks: beat.positionTicks, isPaused: beat.isPaused, itemID: beat.itemID))
    }

    func reportStopped(_ beat: ProgressBeat) async {
        events.append(.stopped(ticks: beat.positionTicks, itemID: beat.itemID))
    }

    func stopEncoding(playSessionID: String) async {
        stoppedEncodings.append(playSessionID)
    }

    func pingSession(playSessionID: String) async {
        pings.append(playSessionID)
    }
}

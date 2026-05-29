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

    func reportStart(_ beat: ProgressBeat) async {
        events.append(.start(ticks: beat.positionTicks, isPaused: beat.isPaused, itemID: beat.itemID))
    }

    func reportProgress(_ beat: ProgressBeat) async {
        events.append(.progress(ticks: beat.positionTicks, isPaused: beat.isPaused, itemID: beat.itemID))
    }

    func reportStopped(_ beat: ProgressBeat) async {
        events.append(.stopped(ticks: beat.positionTicks, itemID: beat.itemID))
    }
}

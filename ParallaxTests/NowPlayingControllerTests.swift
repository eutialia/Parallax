import CoreMedia
import MediaPlayer
import Testing
@testable import Parallax

/// `NowPlayingController` against the live `MPNowPlayingInfoCenter`: for these the info center IS
/// the subject under test. It is a process-wide singleton, so `.serialized` keeps the cases off
/// each other's write.
@Suite("NowPlayingController", .serialized)
@MainActor
struct NowPlayingControllerTests {
    @Test("NowPlayingController.update writes elapsed/duration/rate into MPNowPlayingInfoCenter.default")
    func nowPlayingUpdate() {
        let controller = NowPlayingController()
        controller.update(position: CMTime(seconds: 60, preferredTimescale: 600),
                          duration: CMTime(seconds: 7200, preferredTimescale: 600),
                          isPlaying: true, title: "Test Movie")
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 60.0)
        #expect((info[MPMediaItemPropertyPlaybackDuration] as? Double) == 7200.0)
        #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 1.0)
        #expect((info[MPMediaItemPropertyTitle] as? String) == "Test Movie")
    }

    @Test("NowPlayingController.update sets rate 0 when paused")
    func nowPlayingPaused() {
        let controller = NowPlayingController()
        controller.update(position: CMTime(seconds: 120, preferredTimescale: 600),
                          duration: CMTime(seconds: 7200, preferredTimescale: 600),
                          isPlaying: false, title: "Test Movie")
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0.0)
        #expect((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 120.0)
    }
}

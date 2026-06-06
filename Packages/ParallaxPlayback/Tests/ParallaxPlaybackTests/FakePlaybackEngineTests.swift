import Foundation
import CoreMedia
import Testing
import ParallaxPlayback
import ParallaxPlaybackTestSupport

@Suite("FakePlaybackEngine")
@MainActor
struct FakePlaybackEngineTests {

    @Test("id and capabilities match constructor arguments")
    func idAndCapabilities() {
        let caps = PlaybackEngineCapabilities(
            supportsPiP: false, supportsVideoAirPlay: false,
            supportsAudioAirPlay: false, supportsNowPlayingIntegration: false
        )
        let fake = FakePlaybackEngine(id: .avKit, capabilities: caps)
        #expect(fake.id == .avKit)
        #expect(fake.capabilities == caps)
    }

    @Test("load records the asset and emits .loading then .ready on script")
    func loadRecordsAsset() async throws {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let url = URL(string: "https://example.com/stream.mp4")!
        let hints = PlaybackHints(scheme: "https", container: .mp4, videoCodec: .h264, audioCodec: .aac, subtitleFormats: [])
        let asset = PlayableAsset(url: url, headers: nil, hints: hints, startTime: nil)

        var received: [PlaybackState] = []
        let task = Task {
            for await state in fake.state {
                received.append(state)
                if received.count == 2 { break }
            }
        }

        try await fake.load(asset)
        let duration = CMTime(seconds: 3600, preferredTimescale: 1000)
        fake.push(.loading)
        fake.push(.ready(duration: duration, tracks: .empty))

        await task.value

        #expect(fake.loadedAssets.count == 1)
        #expect(fake.loadedAssets.first?.url == url)
        #expect(received.count == 2)
        if case .ready(let d, _) = received[1] {
            #expect(d == duration)
        } else {
            Issue.record("Expected .ready as second state")
        }
    }

    @Test("play/pause/seek/teardown record call order")
    func callOrder() async {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        await fake.play()
        await fake.pause()
        await fake.seek(to: CMTime(seconds: 30, preferredTimescale: 1000))
        await fake.teardown()
        #expect(fake.calls == ["play", "pause", "seek(30.0)", "teardown"])
    }

    @Test("setAudioTrack records the selected track id")
    func setAudioTrack() async {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let track = AudioTrack(id: .vlc("a1"), displayName: "English", languageCode: "en")
        await fake.setAudioTrack(track)
        #expect(fake.selectedAudioTrackID == .vlc("a1"))
    }

    @Test("setSubtitleTrack nil clears the selection")
    func setSubtitleTrackNil() async {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let track = SubtitleTrack(id: .vlc("s1"), displayName: "French", languageCode: "fr", isForced: false)
        await fake.setSubtitleTrack(track)
        #expect(fake.selectedSubtitleTrackID == .vlc("s1"))
        await fake.setSubtitleTrack(nil)
        #expect(fake.selectedSubtitleTrackID == nil)
    }

    @Test("teardown finishes the state stream")
    func teardownFinishesStream() async {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        var count = 0
        let task = Task {
            for await _ in fake.state { count += 1 }
        }
        fake.push(.idle)
        fake.push(.loading)
        await fake.teardown()
        await task.value
        #expect(count == 2)
    }
}

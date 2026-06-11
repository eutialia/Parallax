import Foundation
import CoreMedia
import Testing
import ParallaxCore
import ParallaxPlayback

@Suite("Value types")
struct ValueTypeTests {

    @Test("PlaybackEngineID raw values match expected strings")
    func playbackEngineIDRawValues() {
        #expect(PlaybackEngineID.avKit.rawValue == "avKit")
        #expect(PlaybackEngineID.vlcKit.rawValue == "vlcKit")
    }

    @Test("PlaybackEngineID is Hashable and distinct")
    func playbackEngineIDHashable() {
        let s: Set<PlaybackEngineID> = [.avKit, .vlcKit, .avKit]
        #expect(s.count == 2)
    }

    @Test("PlaybackHints stores all fields verbatim")
    func playbackHintsFields() {
        let hints = PlaybackHints(
            scheme: "https",
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            subtitleFormats: [.vtt, .srt]
        )
        #expect(hints.scheme == "https")
        #expect(hints.container == .mp4)
        #expect(hints.videoCodec == .h264)
        #expect(hints.audioCodec == .aac)
        #expect(hints.subtitleFormats == [.vtt, .srt])
    }

    @Test("PlaybackHints with all-nil optional fields compiles and is Hashable")
    func playbackHintsNilFields() {
        let a = PlaybackHints(scheme: nil, container: nil, videoCodec: nil, audioCodec: nil, subtitleFormats: [])
        let b = PlaybackHints(scheme: nil, container: nil, videoCodec: nil, audioCodec: nil, subtitleFormats: [])
        #expect(a == b)
    }

    @Test("PlayableAsset stores url, headers, hints, startTime")
    func playableAssetFields() {
        let url = URL(string: "https://jellyfin.example.com/stream.mp4?api_key=abc")!
        let hints = PlaybackHints(scheme: "https", container: .mp4, videoCodec: .h264, audioCodec: .aac, subtitleFormats: [])
        let start = CMTime(seconds: 120, preferredTimescale: 1000)
        let asset = PlayableAsset(url: url, headers: nil, hints: hints, startTime: start)
        #expect(asset.url == url)
        #expect(asset.headers == nil)
        #expect(asset.hints == hints)
        #expect(asset.startTime == start)
    }

    @Test("AudioTrack is Hashable and stores all fields")
    func audioTrackFields() {
        let track = AudioTrack(id: .avKitOption(1), displayName: "English AAC 5.1", languageCode: "en")
        #expect(track.id == .avKitOption(1))
        #expect(track.displayName == "English AAC 5.1")
        #expect(track.languageCode == "en")
        let set: Set<AudioTrack> = [track, track]
        #expect(set.count == 1)
    }

    @Test("SubtitleTrack isForced flag round-trips")
    func subtitleTrackForced() {
        let forced = SubtitleTrack(id: .avKitOption(2), displayName: "English (Forced)", languageCode: "en", isForced: true)
        let normal = SubtitleTrack(id: .avKitOption(3), displayName: "English", languageCode: "en", isForced: false)
        #expect(forced.isForced == true)
        #expect(normal.isForced == false)
        #expect(forced != normal)
    }

    @Test("TrackInventory.empty has no tracks")
    func trackInventoryEmpty() {
        let inv = TrackInventory.empty
        #expect(inv.audio.isEmpty)
        #expect(inv.subtitles.isEmpty)
    }

    @Test("TrackInventory stores audio and subtitle tracks")
    func trackInventoryPopulated() {
        let audio = [AudioTrack(id: .vlc("a1"), displayName: "English", languageCode: "en")]
        let subs = [SubtitleTrack(id: .vlc("s1"), displayName: "French", languageCode: "fr", isForced: false)]
        let inv = TrackInventory(audio: audio, subtitles: subs)
        #expect(inv.audio.count == 1)
        #expect(inv.subtitles.count == 1)
        #expect(inv == TrackInventory(audio: audio, subtitles: subs))
    }

    @Test("PlaybackState cases compile and carry associated values")
    func playbackStateCases() {
        let duration = CMTime(seconds: 7200, preferredTimescale: 1000)
        let position = CMTime(seconds: 60, preferredTimescale: 1000)
        let states: [PlaybackState] = [
            .idle,
            .loading,
            .ready(duration: duration, tracks: .empty),
            .playing(position: position, duration: duration, buffered: nil),
            .paused(position: position, duration: duration, buffered: nil),
            .buffering(position: position, duration: duration, buffered: nil),
            .ended,
            .failed(.networkStalled),
        ]
        #expect(states.count == 8)
        if case .ready(let d, let t) = states[2] {
            #expect(d == duration)
            #expect(t == .empty)
        } else {
            Issue.record("Expected .ready")
        }
        if case .buffering(let p, let d, let b) = states[5] {
            #expect(p == position)
            #expect(d == duration)
            #expect(b == nil)
        } else {
            Issue.record("Expected .buffering")
        }
        if case .failed(let e) = states[7] {
            #expect(e == .networkStalled)
        } else {
            Issue.record("Expected .failed(.networkStalled)")
        }
    }

    @Test("PlaybackError.unknown carries its message string")
    func playbackErrorUnknown() {
        let e = PlaybackError.unknown("boom")
        if case .unknown(let msg) = e {
            #expect(msg == "boom")
        } else {
            Issue.record("Expected .unknown")
        }
    }

    @Test("PlaybackEngine protocol requirements are visible")
    func playbackEngineProtocolExists() {
        // Verify the protocol is importable and the associated type names match the spec.
        // FakePlaybackEngine (Task 4a.6) is the concrete conformance; this test
        // is a compile-time assertion that the protocol surface exists.
        let _: (any PlaybackEngine).Type = (any PlaybackEngine).self
        #expect(Bool(true))
    }

    @Test("PlaybackEngineCapabilities AVKit preset has all capabilities true")
    func playbackEngineCapabilitiesAVKit() {
        let caps = PlaybackEngineCapabilities(
            supportsPiP: true,
            supportsVideoAirPlay: true,
            supportsAudioAirPlay: true,
            supportsNowPlayingIntegration: true
        )
        #expect(caps.supportsPiP)
        #expect(caps.supportsVideoAirPlay)
        #expect(caps.supportsAudioAirPlay)
        #expect(caps.supportsNowPlayingIntegration)
        #expect(caps == caps)
    }
}

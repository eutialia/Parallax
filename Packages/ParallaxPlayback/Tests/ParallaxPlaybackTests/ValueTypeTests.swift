import Foundation
import CoreMedia
import Testing
import ParallaxCore
@testable import ParallaxPlayback

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

    @Test("ExternalSubtitle stores url, format, languageCode, isForced")
    func externalSubtitleFields() {
        let url = URL(string: "https://example.com/sub.ass")!
        let sub = ExternalSubtitle(url: url, format: .ass, languageCode: "en", isForced: false)
        #expect(sub.url == url)
        #expect(sub.format == .ass)
        #expect(sub.languageCode == "en")
        #expect(sub.isForced == false)
    }

    @Test("ExternalSubtitle with nil languageCode is Hashable")
    func externalSubtitleNilLang() {
        let url = URL(string: "https://example.com/sub.vtt")!
        let a = ExternalSubtitle(url: url, format: .vtt, languageCode: nil, isForced: true)
        let b = ExternalSubtitle(url: url, format: .vtt, languageCode: nil, isForced: true)
        #expect(a == b)
    }

    @Test("PlayableAsset stores url, headers, hints, startTime, externalSubtitles")
    func playableAssetFields() {
        let url = URL(string: "https://jellyfin.example.com/stream.mp4?api_key=abc")!
        let hints = PlaybackHints(scheme: "https", container: .mp4, videoCodec: .h264, audioCodec: .aac, subtitleFormats: [])
        let start = CMTime(seconds: 120, preferredTimescale: 1000)
        let asset = PlayableAsset(url: url, headers: nil, hints: hints, startTime: start, externalSubtitles: [])
        #expect(asset.url == url)
        #expect(asset.headers == nil)
        #expect(asset.hints == hints)
        #expect(asset.startTime == start)
        #expect(asset.externalSubtitles.isEmpty)
    }
}

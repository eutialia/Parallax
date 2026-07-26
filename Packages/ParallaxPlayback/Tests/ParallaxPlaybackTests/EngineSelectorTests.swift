import Foundation
import Testing
import ParallaxCore
import ParallaxPlayback
import ParallaxPlaybackTestSupport

/// The selector is a pure routing function over five axes, so the suite is written as
/// the routing matrix it is. The per-axis tests are *exhaustive over the enum* — a new
/// `Container`/`VideoCodec`/`AudioCodec`/`SubtitleFormat` case added to ParallaxCore
/// without a matrix entry fails here instead of silently routing to AVKit and failing
/// on a device.
@Suite("EngineSelector routing matrix")
struct EngineSelectorTests {

    private func expected(_ isAVKitPlayable: Bool) -> PlaybackEngineID {
        isAVKitPlayable ? .avKit : .vlcKit
    }

    // MARK: — Per-axis, exhaustive over every case ParallaxCore declares

    @Test("container routing agrees with the AVKit whitelist for every container",
          arguments: Container.allCases)
    func containerRouting(container: Container) {
        let hints = PlaybackHints.fixture(container: container, video: .h264, audio: .aac)
        #expect(EngineSelector.select(hints: hints)
                == expected(PlaybackCapabilityMatrix.avKitContainers.contains(container)))
    }

    @Test("video-codec routing agrees with the AVKit whitelist for every codec",
          arguments: VideoCodec.allCases)
    func videoCodecRouting(codec: VideoCodec) {
        let hints = PlaybackHints.fixture(container: .mp4, video: codec, audio: .aac)
        #expect(EngineSelector.select(hints: hints)
                == expected(PlaybackCapabilityMatrix.avKitVideoCodecs.contains(codec)))
    }

    @Test("audio-codec routing agrees with the AVKit whitelist for every codec",
          arguments: AudioCodec.allCases)
    func audioCodecRouting(codec: AudioCodec) {
        let hints = PlaybackHints.fixture(container: .mp4, video: .h264, audio: codec)
        #expect(EngineSelector.select(hints: hints)
                == expected(PlaybackCapabilityMatrix.avKitAudioCodecs.contains(codec)))
    }

    @Test("subtitle routing agrees with the AVKit whitelist for every format",
          arguments: SubtitleFormat.allCases)
    func subtitleRouting(format: SubtitleFormat) {
        let hints = PlaybackHints.fixture(subtitles: [format])
        #expect(EngineSelector.select(hints: hints)
                == expected(PlaybackCapabilityMatrix.avKitSubtitleFormats.contains(format)))
    }

    /// One disqualifying format in a mixed list is enough — the manifest can't be split
    /// across engines.
    @Test("a single non-AVPlayer subtitle format in a mixed list still forces VLC",
          arguments: [[SubtitleFormat.vtt, .ass], [.srt, .pgs], [.vtt, .srt, .vobsub]])
    func mixedSubtitleListsFollowTheWorstCase(formats: [SubtitleFormat]) {
        #expect(EngineSelector.select(hints: .fixture(subtitles: formats)) == .vlcKit)
    }

    // MARK: — Absent hints

    /// Nothing known is not a reason to reach for VLC: the transcode path delivers HLS,
    /// which is AVPlayer's native format.
    @Test("hints with no signal at all default to AVKit")
    func allNilHints() {
        #expect(EngineSelector.select(hints: .unknown) == .avKit)
    }

    @Test("an unknown axis never disqualifies on its own", arguments: [
        ("no container", PlaybackHints.fixture(container: nil)),
        ("no video codec", PlaybackHints.fixture(video: nil)),
        ("no audio codec", PlaybackHints.fixture(audio: nil)),
        ("no scheme", PlaybackHints.fixture(scheme: nil)),
    ])
    func nilAxisDoesNotForceVLC(label: String, hints: PlaybackHints) {
        #expect(EngineSelector.select(hints: hints) == .avKit, "\(label) should stay on AVKit")
    }

    // MARK: — Priority: the scheme check outranks every format check

    /// The discriminating case: every *other* axis says AVKit (mp4 / h264 / aac / vtt),
    /// so a `.vlcKit` result can only come from the scheme rule. AVPlayer cannot open
    /// `smb://` at all, which is why this rule has to win.
    @Test("smb wins over hints that would otherwise route to AVKit")
    func smbSchemeOutranksAVKitFriendlyHints() {
        let hints = PlaybackHints.fixture(
            scheme: "smb", container: .mp4, video: .h264, audio: .aac, subtitles: [.vtt]
        )
        #expect(EngineSelector.select(hints: hints) == .vlcKit)
    }

    @Test("only the smb scheme routes on scheme alone",
          arguments: ["http", "https", "file", "SMB", "smbx", ""])
    func otherSchemesDoNotForceVLC(scheme: String) {
        #expect(EngineSelector.select(hints: .fixture(scheme: scheme)) == .avKit)
    }

    // MARK: — 5d regression guard

    /// After the server remuxes mkv+hevc it *delivers* HLS; the selector sees the
    /// delivered stream, never the source. Routing this to VLC was the 5d bug.
    @Test("an HLS transcode delivery routes to AVKit even with no codec hints")
    func hlsTranscodeDeliveryAVKit() {
        let hints = PlaybackHints.fixture(container: .hls, video: nil, audio: nil)
        #expect(EngineSelector.select(hints: hints) == .avKit)
    }
}

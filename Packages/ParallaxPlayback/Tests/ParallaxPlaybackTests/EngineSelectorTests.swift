import Foundation
import Testing
import ParallaxCore
import ParallaxPlayback
import ParallaxPlaybackTestSupport

/// The selector is a pure routing function over the hints and the device's AVPlayer
/// support, so the suite is written as the routing table it is.
@Suite("EngineSelector routing matrix")
struct EngineSelectorTests {

    private func expected(_ isAVKitPlayable: Bool) -> PlaybackEngineID {
        isAVKitPlayable ? .avKit : .vlcKit
    }

    // MARK: — Format axes against the probed support

    static let withoutAV1 = AVPlayerSupport(
        containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc], audioCodecs: [.aac, .ac3, .eac3]
    )
    static let withAV1 = AVPlayerSupport(
        containers: [.mp4, .mov, .hls],
        videoCodecs: [.h264, .hevc, .av1],
        audioCodecs: [.aac, .ac3, .eac3, .flac, .opus]
    )

    struct Route: Sendable, CustomTestStringConvertible {
        let name: String
        let hints: PlaybackHints
        let support: AVPlayerSupport
        let engine: PlaybackEngineID
        var testDescription: String { name }
    }

    static let routes: [Route] = [
        Route(name: "h264/aac mp4", hints: .fixture(), support: withoutAV1, engine: .avKit),
        Route(name: "h264/aac mov", hints: .fixture(container: .mov), support: withoutAV1, engine: .avKit),
        Route(name: "mkv", hints: .fixture(container: .mkv), support: withAV1, engine: .vlcKit),
        Route(name: "av1 without AV1 support", hints: .fixture(video: .av1), support: withoutAV1, engine: .vlcKit),
        Route(name: "av1 with AV1 support", hints: .fixture(video: .av1), support: withAV1, engine: .avKit),
        Route(name: "vp9", hints: .fixture(video: .vp9), support: withAV1, engine: .vlcKit),
        Route(name: "flac without FLAC support", hints: .fixture(audio: [.flac]), support: withoutAV1, engine: .vlcKit),
        Route(name: "flac with FLAC support", hints: .fixture(audio: [.flac]), support: withAV1, engine: .avKit),
        Route(name: "mp3", hints: .fixture(audio: [.mp3]), support: withAV1, engine: .vlcKit),
        Route(name: "aac + dts", hints: .fixture(audio: [.aac, .dts]), support: withAV1, engine: .vlcKit),
        Route(name: "dts + aac", hints: .fixture(audio: [.dts, .aac]), support: withAV1, engine: .vlcKit),
        Route(name: "aac + ac3", hints: .fixture(audio: [.aac, .ac3]), support: withoutAV1, engine: .avKit),
    ]

    @Test("container, video and audio route on the device's AVPlayer support", arguments: routes)
    func formatRouting(route: Route) {
        #expect(EngineSelector.select(hints: route.hints, support: route.support) == route.engine)
    }

    @Test("subtitle routing agrees with the AVKit whitelist for every format",
          arguments: SubtitleFormat.allCases)
    func subtitleRouting(format: SubtitleFormat) {
        let hints = PlaybackHints.fixture(subtitles: [format])
        #expect(EngineSelector.select(hints: hints, support: Self.withoutAV1)
                == expected(PlaybackCapabilityMatrix.avKitSubtitleFormats.contains(format)))
    }

    /// One disqualifying format in a mixed list is enough — the manifest can't be split
    /// across engines.
    @Test("a single non-AVPlayer subtitle format in a mixed list still forces VLC",
          arguments: [[SubtitleFormat.vtt, .ass], [.srt, .pgs], [.vtt, .srt, .vobsub]])
    func mixedSubtitleListsFollowTheWorstCase(formats: [SubtitleFormat]) {
        #expect(EngineSelector.select(hints: .fixture(subtitles: formats), support: Self.withoutAV1) == .vlcKit)
    }

    // MARK: — Absent hints

    /// Nothing known is not a reason to reach for VLC: the transcode path delivers HLS,
    /// which is AVPlayer's native format.
    @Test("hints with no signal at all default to AVKit")
    func allNilHints() {
        #expect(EngineSelector.select(hints: .unknown, support: Self.withoutAV1) == .avKit)
    }

    @Test("an unknown axis never disqualifies on its own", arguments: [
        ("no container", PlaybackHints.fixture(container: nil)),
        ("no video codec", PlaybackHints.fixture(video: nil)),
        ("no audio codec", PlaybackHints.fixture(audio: [])),
        ("no scheme", PlaybackHints.fixture(scheme: nil)),
    ])
    func nilAxisDoesNotForceVLC(label: String, hints: PlaybackHints) {
        #expect(EngineSelector.select(hints: hints, support: Self.withoutAV1) == .avKit, "\(label) should stay on AVKit")
    }

    // MARK: — Priority: the scheme check outranks every format check

    /// The discriminating case: every *other* axis says AVKit (mp4 / h264 / aac / vtt),
    /// so a `.vlcKit` result can only come from the scheme rule. AVPlayer cannot open
    /// `smb://` at all, which is why this rule has to win.
    @Test("smb wins over hints that would otherwise route to AVKit")
    func smbSchemeOutranksAVKitFriendlyHints() {
        let hints = PlaybackHints.fixture(
            scheme: "smb", container: .mp4, video: .h264, audio: [.aac], subtitles: [.vtt]
        )
        #expect(EngineSelector.select(hints: hints, support: Self.withoutAV1) == .vlcKit)
    }

    @Test("only the smb scheme routes on scheme alone",
          arguments: ["http", "https", "file", "SMB", "smbx", ""])
    func otherSchemesDoNotForceVLC(scheme: String) {
        #expect(EngineSelector.select(hints: .fixture(scheme: scheme), support: Self.withoutAV1) == .avKit)
    }

    // MARK: — 5d regression guard

    /// After the server remuxes mkv+hevc it *delivers* HLS; the selector sees the
    /// delivered stream, never the source. Routing this to VLC was the 5d bug.
    @Test("an HLS transcode delivery routes to AVKit even with no codec hints")
    func hlsTranscodeDeliveryAVKit() {
        let hints = PlaybackHints.fixture(container: .hls, video: nil, audio: [])
        #expect(EngineSelector.select(hints: hints, support: Self.withoutAV1) == .avKit)
    }
}

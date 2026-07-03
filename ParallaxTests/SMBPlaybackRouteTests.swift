import Foundation
import Testing
import ParallaxCore
import ParallaxPlayback
@testable import Parallax

/// The pure routing decision `SMBPlaybackResolver.route` makes from a probe result:
/// bridge (AVKit over the localhost HTTP bridge) vs the legacy `smb://`+VLC route,
/// plus the `PlaybackHints` each route carries. No I/O — every case is a table row.
@Suite("SMBPlaybackResolver.route")
struct SMBPlaybackRouteTests {

    @Test("complete h264/aac mp4 rides the bridge with http hints")
    func completeH264AACRidesBridge() {
        let probe = MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: true
        )
        let (hints, useBridge) = SMBPlaybackResolver.route(probe: probe, sizeBytes: 1_234)

        #expect(useBridge)
        #expect(hints.scheme == "http")
        #expect(hints.container == .mp4)
        #expect(hints.videoCodec == .h264)
        #expect(hints.audioCodec == .aac)
        #expect(hints.fileSizeBytes == 1_234)
    }

    @Test("incomplete file never bridges — VLC owns the read-rate duration estimate")
    func incompleteFallsBackToVLC() {
        let probe = MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.aac), isComplete: false
        )
        let (hints, useBridge) = SMBPlaybackResolver.route(probe: probe, sizeBytes: 1_234)

        #expect(!useBridge)
        #expect(hints.scheme == "smb")
        #expect(hints.container == .mp4)
        #expect(hints.fileSizeBytes == 1_234)
    }

    @Test("dts audio falls back to VLC (not an AVKit audio codec)")
    func dtsAudioFallsBackToVLC() {
        let probe = MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .known(.dts), isComplete: true
        )
        let (hints, useBridge) = SMBPlaybackResolver.route(probe: probe, sizeBytes: nil)

        #expect(!useBridge)
        #expect(hints.scheme == "smb")
        #expect(hints.audioCodec == .dts)
    }

    @Test("nil probe (timeout/failure) falls back to VLC with nil codecs, smb scheme")
    func nilProbeFallsBackToVLC() {
        let (hints, useBridge) = SMBPlaybackResolver.route(probe: nil, sizeBytes: 42)

        #expect(!useBridge)
        #expect(hints.scheme == "smb")
        #expect(hints.container == nil)
        #expect(hints.videoCodec == nil)
        #expect(hints.audioCodec == nil)
        #expect(hints.fileSizeBytes == 42)
    }

    @Test("av1 mp4 falls back to VLC (selector rule 4 — not an AVKit video codec)")
    func av1FallsBackToVLC() {
        let probe = MediaProbeResult(
            container: .mp4, videoCodec: .known(.av1), audioCodec: .known(.aac), isComplete: true
        )
        let (hints, useBridge) = SMBPlaybackResolver.route(probe: probe, sizeBytes: nil)

        #expect(!useBridge)
        #expect(hints.scheme == "smb")
        #expect(hints.videoCodec == .av1)
    }

    @Test("a codec-unknown track never bridges even when otherwise AVKit-clean")
    func unknownCodecFallsBackToVLC() {
        let probe = MediaProbeResult(
            container: .mp4, videoCodec: .known(.h264), audioCodec: .unknown, isComplete: true
        )
        let (hints, useBridge) = SMBPlaybackResolver.route(probe: probe, sizeBytes: nil)

        #expect(!useBridge)
        #expect(hints.scheme == "smb")
        // An unknown codec maps to nil in hints (only the known value survives).
        #expect(hints.audioCodec == nil)
    }
}

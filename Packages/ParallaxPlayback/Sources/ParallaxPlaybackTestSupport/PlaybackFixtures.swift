import CoreMedia
import Foundation
import ParallaxCore
import ParallaxPlayback

// MARK: — PlaybackHints

extension PlaybackHints {
    /// The AVKit-happy baseline (`https` + `mp4` + `h264` + `aac`, no subtitles) that
    /// every routing / cache-depth / load test varies exactly one axis of.
    ///
    /// One builder for the whole target: the routing matrix, the VLC cache-depth table
    /// and the engine-load fixtures all used to rebuild these same four fields inline.
    public static func fixture(
        scheme: String? = "https",
        container: Container? = .mp4,
        video: VideoCodec? = .h264,
        audio: AudioCodec? = .aac,
        subtitles: [SubtitleFormat] = [],
        fileSizeBytes: Int64? = nil
    ) -> PlaybackHints {
        PlaybackHints(
            scheme: scheme,
            container: container,
            videoCodec: video,
            audioCodec: audio,
            subtitleFormats: subtitles,
            fileSizeBytes: fileSizeBytes
        )
    }

    /// Hints carrying no signal at all — the "server transcoded it, we know nothing"
    /// shape the selector must still route.
    public static let unknown = PlaybackHints.fixture(
        scheme: nil, container: nil, video: nil, audio: nil
    )
}

// MARK: — PlayableAsset

extension PlayableAsset {
    /// A loadable asset over the AVKit-happy hint baseline.
    public static func fixture(
        url: URL = URL(string: "https://example.com/stream.mp4")!,
        headers: [String: String]? = nil,
        hints: PlaybackHints = .fixture(),
        startTime: CMTime? = nil
    ) -> PlayableAsset {
        PlayableAsset(url: url, headers: headers, hints: hints, startTime: startTime)
    }
}

// MARK: — CountingFakeCapabilityProbe

/// `FakeCapabilityProbe` plus a probe-call counter, for the `DeviceProfileBuilder`
/// cache/invalidate contract.
///
/// `@MainActor` (not an `actor`) so the count increments *synchronously* inside
/// `hdrSupport()`. An earlier `actor` version recorded each call through a
/// fire-and-forget `Task { await recordCall() }`, which raced the test's
/// `await probe.callCount` read and failed non-deterministically under parallel
/// execution. `DeviceProfileBuilder.build()` awaits the `@MainActor` `hdrSupport()`
/// before returning, so by the time a test reads `callCount` the increment has landed.
@MainActor
public final class CountingFakeCapabilityProbe: CapabilityProbe {
    private let stubbedHDR: HDRSupport
    private let stubbedAudioOutput: AudioOutputCapability
    public private(set) var callCount = 0

    public nonisolated init(
        hdr: HDRSupport = .none,
        audioOutput: AudioOutputCapability = .stereo
    ) {
        self.stubbedHDR = hdr
        self.stubbedAudioOutput = audioOutput
    }

    public func hdrSupport() -> HDRSupport {
        callCount += 1
        return stubbedHDR
    }

    public nonisolated func audioOutput() -> AudioOutputCapability {
        stubbedAudioOutput
    }
}

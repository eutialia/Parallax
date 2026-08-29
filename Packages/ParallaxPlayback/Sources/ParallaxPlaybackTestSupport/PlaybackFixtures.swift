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
        startTime: CMTime? = nil,
        subtitleFontsDirectory: URL? = nil,
        subtitleFontFamily: String? = nil,
        subtitleTextStyle: EngineSubtitleTextStyle? = nil,
        engineSubtitlesDisabled: Bool = false,
        vlcOptions: [String]? = nil,
        vlcLibraryOptions: [String]? = nil
    ) -> PlayableAsset {
        PlayableAsset(
            url: url,
            headers: headers,
            hints: hints,
            startTime: startTime,
            subtitleFontsDirectory: subtitleFontsDirectory,
            subtitleFontFamily: subtitleFontFamily,
            subtitleTextStyle: subtitleTextStyle,
            engineSubtitlesDisabled: engineSubtitlesDisabled,
            vlcOptions: vlcOptions,
            vlcLibraryOptions: vlcLibraryOptions
        )
    }
}

// MARK: — PlaybackState

extension PlaybackState {
    /// The position-carrying beats, terse. `PlaybackState` deliberately has no default for
    /// `provenance` — `.observed` is the contract's strongest claim, and a forgotten label
    /// would compile straight into it at whatever production site forgot it — but a scripted
    /// test beat usually IS an ordinary clock, so the default belongs here instead: one place,
    /// visible in the fixture rather than invisible in the enum.
    ///
    /// Seconds rather than `CMTime` because that is what every assertion reads back
    /// (`CMTimeGetSeconds`); the timescale is fixed at 600 (`CMTime` compares across
    /// timescales, so it can differ from a production beat's without changing an outcome).
    public static func playing(
        _ seconds: Double,
        duration: CMTime = .fixtureDuration,
        buffered: CMTime? = nil,
        provenance: PositionProvenance = .observed
    ) -> PlaybackState {
        .playing(position: .seconds(seconds), duration: duration,
                 buffered: buffered, provenance: provenance)
    }

    public static func paused(
        _ seconds: Double,
        duration: CMTime = .fixtureDuration,
        buffered: CMTime? = nil,
        provenance: PositionProvenance = .observed
    ) -> PlaybackState {
        .paused(position: .seconds(seconds), duration: duration,
                buffered: buffered, provenance: provenance)
    }

    public static func buffering(
        _ seconds: Double,
        duration: CMTime = .fixtureDuration,
        buffered: CMTime? = nil,
        provenance: PositionProvenance = .observed
    ) -> PlaybackState {
        .buffering(position: .seconds(seconds), duration: duration,
                   buffered: buffered, provenance: provenance)
    }
}

extension CMTime {
    /// A whole-seconds time at the 600 timescale the app's own seeks use.
    public static func seconds(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// The two-hour runtime the player fixtures are parked in. Arbitrary, and that is the
    /// point: a beat's duration is a backdrop for almost every position assertion, so naming
    /// it once keeps the interesting number (the position) the only one in the call.
    public static let fixtureDuration = CMTime.seconds(7_200)
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

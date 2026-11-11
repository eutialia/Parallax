import CoreMedia
import Foundation
import Synchronization
import ParallaxCore
import ParallaxPlayback

// MARK: — PlayableAsset

extension PlayableAsset {
    public static func fixture(
        url: URL = URL(string: "https://example.com/stream.mp4")!,
        startTime: CMTime? = nil,
        engineSubtitlesDisabled: Bool = false
    ) -> PlayableAsset {
        PlayableAsset(
            url: url,
            startTime: startTime,
            engineSubtitlesDisabled: engineSubtitlesDisabled
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
/// cache/invalidate contract. The count increments synchronously inside `hdrSupport()`,
/// so by the time `build()` returns a test reads the landed value.
public final class CountingFakeCapabilityProbe: CapabilityProbe {
    private let stubbedHDR: HDRSupport
    private let stubbedAVPlayer: AVPlayerSupport
    private let calls = Mutex(0)

    public init(hdr: HDRSupport = .none, avPlayer: AVPlayerSupport = .baseline) {
        self.stubbedHDR = hdr
        self.stubbedAVPlayer = avPlayer
    }

    public var callCount: Int { calls.withLock { $0 } }

    public func hdrSupport() -> HDRSupport {
        calls.withLock { $0 += 1 }
        return stubbedHDR
    }

    public func avPlayerSupport() -> AVPlayerSupport { stubbedAVPlayer }
}

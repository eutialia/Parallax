import Foundation
import ParallaxCore

/// Builds a `DeviceCapabilities` value describing what this device can play
/// via AVPlayer, with a minimal runtime probe for HDR and audio-output.
///
/// The fixed AVPlayer whitelist (codecs, containers, resolution, bitrate) is
/// sourced from `PlaybackCapabilityMatrix` — a single declaration shared with
/// `EngineSelector`. Only `hdr` and `audioOutput` are probed via the injected
/// `CapabilityProbe` so that `ParallaxPlayback` stays free of iOS-only APIs.
///
/// `build()` caches the result after the first probe; `invalidate()` clears
/// the cache so the next `build()` re-probes. The app target calls
/// `invalidate()` when `AudioSessionControlling.routeChanges` fires — the
/// new profile is used on the next `PlaybackInfoService.resolve(...)` call.
public actor DeviceProfileBuilder {
    private let probe: any CapabilityProbe
    private var cached: DeviceCapabilities?

    public init(probe: any CapabilityProbe) {
        self.probe = probe
    }

    /// Returns a `DeviceCapabilities` for the current device, building and
    /// caching it on first call. Subsequent calls return the cached value
    /// until `invalidate()` is called.
    public func build() async -> DeviceCapabilities {
        if let cached { return cached }
        let hdr = await probe.hdrSupport()           // hops to @MainActor, then returns
        let audioOutput = probe.audioOutput()
        let caps = DeviceCapabilities(
            supportedVideoCodecs: PlaybackCapabilityMatrix.avKitVideoCodecs
                .sorted(by: { $0.rawValue < $1.rawValue }),
            supportedAudioCodecs: PlaybackCapabilityMatrix.avKitAudioCodecs
                .sorted(by: { $0.rawValue < $1.rawValue }),
            supportedContainers: PlaybackCapabilityMatrix.avKitContainers
                .sorted(by: { $0.rawValue < $1.rawValue }),
            hdr: hdr,
            maxResolution: .uhd4K,
            maxBitrate: .megabits(120),              // sentinel "high"; wire profile sends no cap
            audioOutput: audioOutput,
            preferredSubtitleFormats: PlaybackCapabilityMatrix.avKitSubtitleFormats
                .sorted(by: { $0.rawValue < $1.rawValue }),
            softwareVideoCodecs: PlaybackCapabilityMatrix.softwareVideoCodecs
                .sorted(by: { $0.rawValue < $1.rawValue }),
            softwareAudioCodecs: PlaybackCapabilityMatrix.softwareAudioCodecs
                .sorted(by: { $0.rawValue < $1.rawValue }),
            softwareContainers: PlaybackCapabilityMatrix.softwareContainers
                .sorted(by: { $0.rawValue < $1.rawValue })
        )
        cached = caps
        return caps
    }

    /// Clears the cached `DeviceCapabilities`, forcing a re-probe on the
    /// next `build()` call. Call this when the audio route changes.
    public func invalidate() {
        cached = nil
    }
}

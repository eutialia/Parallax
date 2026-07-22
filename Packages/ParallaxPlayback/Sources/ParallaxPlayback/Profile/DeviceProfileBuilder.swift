import Foundation
import os
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
/// the cache so the next `build()` re-probes. The app target invalidates on
/// three triggers — an audio route change, a network-constraint change
/// (`setNetworkConstrained`, below), and an HDR-eligibility change — and each
/// time the new profile is used on the next `PlaybackInfoService.resolve(...)`
/// call.
public actor DeviceProfileBuilder {
    private let probe: any CapabilityProbe
    private var cached: DeviceCapabilities?
    /// `true` when the OS last reported a constrained path (Low Data Mode).
    /// Drives `maxBitrate` in `build()`; only `setNetworkConstrained` mutates it.
    private var networkConstrained = false

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
            // Unlimited by default: 360 Mbps LAN ceiling, serialized into the wire profile —
            // above UHD-BD's ~144 Mbps so it never forces a bitrate transcode; nil would mean
            // Jellyfin's 8 Mbps default. The ONLY throttle is reactive: once the OS reports a
            // constrained path (Low Data Mode), clamp to 8 Mbps — Jellyfin's own capped-client
            // default, known to produce a good 1080p transcode. `isExpensive` is deliberately
            // not consulted; cellular/hotspot alone isn't a reason to throttle.
            maxBitrate: networkConstrained ? .megabits(8) : .megabits(360),
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

    /// Records the OS's current Low Data Mode / constrained-path signal. Self-deduping — a
    /// no-op unless the value actually changed — so callers can forward every reachability
    /// update without checking first; only a genuine flip clears the cache.
    public func setNetworkConstrained(_ constrained: Bool) {
        guard constrained != networkConstrained else { return }
        networkConstrained = constrained
        cached = nil
        Log.playback.info("Device profile: networkConstrained → \(constrained), cache invalidated")
    }
}

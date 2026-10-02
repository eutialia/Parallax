import Foundation

public struct DeviceCapabilities: Sendable, Hashable {
    // MARK: - Hardware / AVKit-native tier
    public let supportedVideoCodecs: [VideoCodec]
    public let supportedAudioCodecs: [AudioCodec]
    public let supportedContainers: [Container]
    public let hdr: HDRSupport
    public let maxResolution: Resolution
    public let maxBitrate: Bitrate
    public let preferredSubtitleFormats: [SubtitleFormat]

    // MARK: - Software / VLC-additional tier (Phase 5)
    /// Video codecs the VLC engine handles that AVKit cannot — e.g. VP9, AV1.
    /// Derives from `PlaybackCapabilityMatrix.softwareVideoCodecs` in
    /// `DeviceProfileBuilder`. `DeviceProfileTranslator` uses this set to author
    /// VLC-tier DirectPlay entries without importing `ParallaxPlayback`.
    public let softwareVideoCodecs: [VideoCodec]

    /// Audio codecs the VLC engine adds beyond AVKit: DTS, FLAC, Opus. TrueHD is not
    /// among them — no shippable libvlc build has a TrueHD/MLP decoder.
    public let softwareAudioCodecs: [AudioCodec]

    /// Containers VLC can open that AVKit cannot: MKV, WebM, TS, etc.
    public let softwareContainers: [Container]

    public init(
        supportedVideoCodecs: [VideoCodec],
        supportedAudioCodecs: [AudioCodec],
        supportedContainers: [Container],
        hdr: HDRSupport,
        maxResolution: Resolution,
        maxBitrate: Bitrate,
        preferredSubtitleFormats: [SubtitleFormat],
        softwareVideoCodecs: [VideoCodec] = [],
        softwareAudioCodecs: [AudioCodec] = [],
        softwareContainers: [Container] = []
    ) {
        self.supportedVideoCodecs = supportedVideoCodecs
        self.supportedAudioCodecs = supportedAudioCodecs
        self.supportedContainers = supportedContainers
        self.hdr = hdr
        self.maxResolution = maxResolution
        self.maxBitrate = maxBitrate
        self.preferredSubtitleFormats = preferredSubtitleFormats
        self.softwareVideoCodecs = softwareVideoCodecs
        self.softwareAudioCodecs = softwareAudioCodecs
        self.softwareContainers = softwareContainers
    }
}

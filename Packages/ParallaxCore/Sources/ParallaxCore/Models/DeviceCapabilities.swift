import Foundation

/// What AVPlayer plays on this device, measured at runtime through system APIs.
public struct AVPlayerSupport: Sendable, Hashable {
    public let containers: Set<Container>
    public let videoCodecs: Set<VideoCodec>
    public let audioCodecs: Set<AudioCodec>

    public init(containers: Set<Container>, videoCodecs: Set<VideoCodec>, audioCodecs: Set<AudioCodec>) {
        self.containers = containers
        self.videoCodecs = videoCodecs
        self.audioCodecs = audioCodecs
    }
}

public struct DeviceCapabilities: Sendable, Hashable {
    // MARK: - Hardware / AVKit-native tier
    public let avPlayer: AVPlayerSupport
    public let hdr: HDRSupport
    public let maxResolution: Resolution
    public let maxBitrate: Bitrate
    public let preferredSubtitleFormats: [SubtitleFormat]

    // MARK: - Software / VLC-additional tier (Phase 5)
    // Each set is the VLC declaration minus `avPlayer`, sorted, so the two tiers never
    // overlap: premium MKV content (HEVC-HDR, etc.) falls through to the AVKit remux tier
    // instead of losing HDR/DV/Atmos to VLC. `DeviceProfileTranslator` authors the VLC-tier
    // DirectPlay entry from them without importing `ParallaxPlayback`.

    /// Video codecs VLC handles that AVPlayer cannot on this device, e.g. VP9, and AV1 on
    /// chips without AV1 hardware.
    public let softwareVideoCodecs: [VideoCodec]

    /// Audio codecs VLC handles that AVPlayer cannot, e.g. DTS. TrueHD is not among them:
    /// no shippable libvlc build has a TrueHD/MLP decoder.
    public let softwareAudioCodecs: [AudioCodec]

    /// Containers VLC can open that AVKit cannot: MKV, WebM, TS, etc.
    public let softwareContainers: [Container]

    public init(
        avPlayer: AVPlayerSupport,
        hdr: HDRSupport,
        maxResolution: Resolution,
        maxBitrate: Bitrate,
        preferredSubtitleFormats: [SubtitleFormat],
        vlcVideoCodecs: Set<VideoCodec> = [],
        vlcAudioCodecs: Set<AudioCodec> = [],
        vlcContainers: Set<Container> = []
    ) {
        self.avPlayer = avPlayer
        self.hdr = hdr
        self.maxResolution = maxResolution
        self.maxBitrate = maxBitrate
        self.preferredSubtitleFormats = preferredSubtitleFormats
        self.softwareVideoCodecs = vlcVideoCodecs.subtracting(avPlayer.videoCodecs).sorted { $0.rawValue < $1.rawValue }
        self.softwareAudioCodecs = vlcAudioCodecs.subtracting(avPlayer.audioCodecs).sorted { $0.rawValue < $1.rawValue }
        self.softwareContainers = vlcContainers.subtracting(avPlayer.containers).sorted { $0.rawValue < $1.rawValue }
    }
}

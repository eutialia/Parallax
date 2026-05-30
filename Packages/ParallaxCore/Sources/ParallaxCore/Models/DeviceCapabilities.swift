import Foundation

public struct DeviceCapabilities: Sendable, Hashable, Codable {
    // MARK: - Hardware / AVKit-native tier
    public let supportedVideoCodecs: [VideoCodec]
    public let supportedAudioCodecs: [AudioCodec]
    public let supportedContainers: [Container]
    public let hdr: HDRSupport
    public let maxResolution: Resolution
    public let maxBitrate: Bitrate
    public let audioOutput: AudioOutputCapability
    public let preferredSubtitleFormats: [SubtitleFormat]

    // MARK: - Software / VLC-additional tier (Phase 5)
    /// Video codecs the VLC engine handles that AVKit cannot — e.g. VP9, AV1.
    /// Derives from `PlaybackCapabilityMatrix.softwareVideoCodecs` in
    /// `DeviceProfileBuilder`. `DeviceProfileTranslator` uses this set to author
    /// VLC-tier DirectPlay entries without importing `ParallaxPlayback`.
    public let softwareVideoCodecs: [VideoCodec]

    /// Audio codecs the VLC engine adds beyond AVKit: DTS, TrueHD, FLAC, Opus.
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
        audioOutput: AudioOutputCapability,
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
        self.audioOutput = audioOutput
        self.preferredSubtitleFormats = preferredSubtitleFormats
        self.softwareVideoCodecs = softwareVideoCodecs
        self.softwareAudioCodecs = softwareAudioCodecs
        self.softwareContainers = softwareContainers
    }

    // MARK: - Test stub
    /// A fully-populated stub for use in tests. Software fields reflect the
    /// `PlaybackCapabilityMatrix` software sets (VP9/AV1, DTS/TrueHD/FLAC/Opus,
    /// MKV/WebM/TS/FLAC/MP3) without importing `ParallaxPlayback`.
    public static let stub = DeviceCapabilities(
        supportedVideoCodecs: [.h264, .hevc],
        supportedAudioCodecs: [.aac, .ac3, .eac3, .mp3],
        supportedContainers: [.mp4, .mov, .hls],
        hdr: .hdr10,
        maxResolution: .uhd4K,
        maxBitrate: .megabits(120),
        audioOutput: .stereo,
        preferredSubtitleFormats: [.vtt, .srt],
        softwareVideoCodecs: [.vp9, .av1],
        softwareAudioCodecs: [.dts, .trueHD, .flac, .opus],
        softwareContainers: [.mkv, .webm, .ts, .flac, .mp3]
    )
}

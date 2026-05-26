import Foundation

public struct DeviceCapabilities: Sendable, Hashable, Codable {
    public let supportedVideoCodecs: [VideoCodec]
    public let supportedAudioCodecs: [AudioCodec]
    public let supportedContainers: [Container]
    public let hdr: HDRSupport
    public let maxResolution: Resolution
    public let maxBitrate: Bitrate
    public let audioOutput: AudioOutputCapability
    public let preferredSubtitleFormats: [SubtitleFormat]

    public init(
        supportedVideoCodecs: [VideoCodec],
        supportedAudioCodecs: [AudioCodec],
        supportedContainers: [Container],
        hdr: HDRSupport,
        maxResolution: Resolution,
        maxBitrate: Bitrate,
        audioOutput: AudioOutputCapability,
        preferredSubtitleFormats: [SubtitleFormat]
    ) {
        self.supportedVideoCodecs = supportedVideoCodecs
        self.supportedAudioCodecs = supportedAudioCodecs
        self.supportedContainers = supportedContainers
        self.hdr = hdr
        self.maxResolution = maxResolution
        self.maxBitrate = maxBitrate
        self.audioOutput = audioOutput
        self.preferredSubtitleFormats = preferredSubtitleFormats
    }
}

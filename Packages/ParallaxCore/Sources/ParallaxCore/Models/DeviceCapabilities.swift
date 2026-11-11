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

    // Apple's HLS Authoring Specification allows H.264, HEVC, Dolby Vision and AV1 video and
    // AAC, AC-3, E-AC-3, ALAC and FLAC audio in fMP4; Opus is not listed. The first entry is
    // what a Jellyfin transcode encodes to, and the server stream-copies the rest.

    /// The video codecs an HLS transcode can deliver to this device, encode target first.
    public var hlsVideoCodecs: [VideoCodec] {
        [.h264, .hevc, .av1].filter(videoCodecs.contains)
    }

    /// The audio codecs an HLS transcode can deliver to this device, encode target first.
    public var hlsAudioCodecs: [AudioCodec] {
        [.aac, .ac3, .eac3, .flac].filter(audioCodecs.contains)
    }
}

public struct DeviceCapabilities: Sendable, Hashable {
    // MARK: - Hardware / AVKit-native tier
    public let avPlayer: AVPlayerSupport
    public let hdr: HDRSupport
    public let maxResolution: Resolution
    public let maxBitrate: Bitrate
    public let preferredSubtitleFormats: [SubtitleFormat]

    public init(
        avPlayer: AVPlayerSupport,
        hdr: HDRSupport,
        maxResolution: Resolution,
        maxBitrate: Bitrate,
        preferredSubtitleFormats: [SubtitleFormat]
    ) {
        self.avPlayer = avPlayer
        self.hdr = hdr
        self.maxResolution = maxResolution
        self.maxBitrate = maxBitrate
        self.preferredSubtitleFormats = preferredSubtitleFormats
    }
}

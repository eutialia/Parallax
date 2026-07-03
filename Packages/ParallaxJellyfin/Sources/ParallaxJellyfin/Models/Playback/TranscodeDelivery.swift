import Foundation

/// What the server's live transcode job is ACTUALLY doing to each stream —
/// the copy-vs-reencode signal `PlaybackInfo` cannot provide (the server
/// reports `Transcode` for stream-copy jobs too; only the running session's
/// `TranscodingInfo` distinguishes them, once ffmpeg has started).
///
/// SDK-free mirror of `JellyfinAPI.TranscodingInfo` so callers above the
/// client don't import the SDK. `transcodeReasons` carries the raw server
/// reason strings for the debug overlay.
public struct TranscodeDelivery: Sendable, Equatable {
    /// The server copied the video bitstream (remux) instead of re-encoding.
    public let isVideoDirect: Bool
    /// The server passed the audio through untouched.
    public let isAudioDirect: Bool
    public let videoCodec: String?
    public let audioCodec: String?
    public let bitrate: Int?
    /// Raw reason strings (e.g. "AudioCodecNotSupported") for diagnostics.
    public let transcodeReasons: [String]

    public init(
        isVideoDirect: Bool,
        isAudioDirect: Bool,
        videoCodec: String?,
        audioCodec: String?,
        bitrate: Int?,
        transcodeReasons: [String]
    ) {
        self.isVideoDirect = isVideoDirect
        self.isAudioDirect = isAudioDirect
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.bitrate = bitrate
        self.transcodeReasons = transcodeReasons
    }
}

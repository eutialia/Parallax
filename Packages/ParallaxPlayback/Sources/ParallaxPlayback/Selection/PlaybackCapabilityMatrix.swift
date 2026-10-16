import ParallaxCore

/// The engines' fixed declarations: the shipped libvlc build's spec, and the subtitle
/// formats AVPlayer renders. What AVPlayer plays is device-dependent and measured at
/// runtime instead (`AVPlayerSupportProbe`).
///
/// `DeviceProfileBuilder` derives the VLC-additional tier as `vlc*` minus the probed
/// `AVPlayerSupport`; `DeviceProfileTranslator` (in ParallaxJellyfin) maps that into the
/// VLC direct-play tier (`vlcDirectPlay`). `EngineSelector` reads `avKitSubtitleFormats`.
public enum PlaybackCapabilityMatrix {

    /// Subtitle formats AVPlayer renders natively (WebVTT in HLS manifest,
    /// or SRT sidecar). ASS/PGS/VobSub require libass/libavcodec → VLC.
    public static let avKitSubtitleFormats: Set<SubtitleFormat> = [.vtt, .srt]

    // MARK: — VLC (libvlc) capability set

    /// Containers VLC's libavformat demuxer supports. Broad; covers the long
    /// tail that AVKit cannot open.
    public static let vlcContainers: Set<Container> = [
        .mp4, .mov, .hls,
        .mkv, .webm, .avi, .ts, .flac, .mp3,
    ]

    /// Video codecs libvlc / VideoToolbox can decode on iOS.
    /// `av1` — VLC software-decodes on chips without AV1 HW; it leaves the VLC tier
    /// wherever the probe finds AVPlayer can play it.
    public static let vlcVideoCodecs: Set<VideoCodec> = [
        .h264, .hevc,   // VideoToolbox HW
        .vp9, .av1,     // VLC software-decodes
        .vc1, .mpeg2video,  // VLC-only; AVKit cannot decode
    ]

    /// Audio codecs VLC decodes.
    ///
    /// `trueHD` is deliberately ABSENT: no shippable libvlc build carries a TrueHD/MLP
    /// decoder (VideoLAN leaves it out of the build-config allowlist — proven on
    /// MobileVLCKit 3.7.3), so advertising it would invite a server to hand us a stream
    /// that decodes to silence.
    public static let vlcAudioCodecs: Set<AudioCodec> = [
        .aac, .ac3, .eac3, .mp3,
        .dts, .flac, .opus,
    ]

    /// Subtitle formats VLC renders. Superset of the AVKit set.
    public static let vlcSubtitleFormats: Set<SubtitleFormat> = [
        .vtt, .srt,     // AVKit set
        .ass, .pgs, .vobsub,
    ]
}

import ParallaxCore

/// Single source of truth for which containers, video codecs, audio codecs, and
/// subtitle formats each playback engine supports.
///
/// `EngineSelector` reads the `avKit*` sets for routing decisions.
/// `DeviceProfileBuilder` derives `DeviceCapabilities` from the matrix.
/// Two live consumers sit downstream: `DeviceProfileTranslator` (in
/// ParallaxJellyfin) maps `DeviceCapabilities` → Jellyfin wire strings for the
/// server negotiation, including the VLC direct-play tier (`vlcDirectPlay`);
/// and `SMBPlaybackResolver` routes probed SMB files through
/// `EngineSelector.select` to decide bridge-to-AVKit vs native VLC. The
/// deliberate `hls`/transcode divergences live in the translator, not in the
/// matrix.
///
/// The `software*` sets are the VLC-additional tier: `vlc* minus avKit*`.
/// They are used by `DeviceCapabilities` (added in Task 5a.4) to tell
/// `DeviceProfileTranslator` which codecs belong to the VLC direct-play tier.
public enum PlaybackCapabilityMatrix {

    // MARK: — AVKit (AVPlayer) whitelist

    /// Containers AVPlayer can demux natively.
    /// Note: `.hls` is a routing and delivery format, not a direct-play source
    /// container — it appears here so `EngineSelector` routes HLS streams to
    /// AVKit and so `DeviceProfileBuilder` includes it in `supportedContainers`.
    /// `DeviceProfileTranslator` deliberately excludes `.hls` from the
    /// DirectPlay container string (only `mp4,mov` are direct-played); that
    /// divergence lives in the translator, not here.
    public static let avKitContainers: Set<Container> = [.mp4, .mov, .hls]

    /// Video codecs VideoToolbox can hardware-decode for AVPlayer.
    public static let avKitVideoCodecs: Set<VideoCodec> = [.h264, .hevc]

    /// Audio codecs AVPlayer's audio pipeline handles.
    public static let avKitAudioCodecs: Set<AudioCodec> = AudioCodec.avPlayerSupported

    /// Subtitle formats AVPlayer renders natively (WebVTT in HLS manifest,
    /// or SRT sidecar). ASS/PGS/VobSub require libass/libavcodec → VLC.
    public static let avKitSubtitleFormats: Set<SubtitleFormat> = [.vtt, .srt]

    // MARK: — VLC (VLCKit 4.x) capability set

    /// Containers VLC's libavformat demuxer supports. Broad; covers the long
    /// tail that AVKit cannot open. The `avi` container is not yet a `Container`
    /// enum case — add it when the enum is extended.
    public static let vlcContainers: Set<Container> = [
        .mp4, .mov, .hls,   // everything AVKit handles
        .mkv, .webm, .avi, .ts, .flac, .mp3,
    ]

    /// Video codecs libvlc / VideoToolbox can decode on iOS.
    /// `av1` — VLC software-decodes on chips without AV1 HW; include it here
    /// and exclude from the AVKit tier (Task 5d decides the chip-gated split;
    /// for the matrix the conservative position is: VLC always handles AV1).
    public static let vlcVideoCodecs: Set<VideoCodec> = [
        .h264, .hevc,   // VideoToolbox HW (same as AVKit)
        .vp9, .av1,     // VLC software-decodes
        .vc1, .mpeg2video,  // VLC-only; AVKit cannot decode
    ]

    /// Audio codecs VLC decodes. Superset of the AVKit set.
    public static let vlcAudioCodecs: Set<AudioCodec> = [
        .aac, .ac3, .eac3, .mp3,   // AVKit set
        .dts, .trueHD, .flac, .opus,
    ]

    /// Subtitle formats VLC renders. Superset of the AVKit set.
    public static let vlcSubtitleFormats: Set<SubtitleFormat> = [
        .vtt, .srt,     // AVKit set
        .ass, .pgs, .vobsub,
    ]

    // MARK: — Derived "software" sets (VLC-additional tier)

    /// Video codecs that VLC can play but AVKit cannot — i.e. the VLC direct-play
    /// tier. Critically excludes `h264` and `hevc` so that premium MKV content
    /// (HEVC-HDR, etc.) falls through to the AVKit remux tier rather than being
    /// routed to VLC and losing HDR/DV/Atmos.
    public static let softwareVideoCodecs: Set<VideoCodec> =
        vlcVideoCodecs.subtracting(avKitVideoCodecs)

    /// Audio codecs that VLC handles beyond AVKit's set (DTS, TrueHD, FLAC,
    /// Opus). Used when authoring the VLC direct-play tier in the device profile.
    public static let softwareAudioCodecs: Set<AudioCodec> =
        vlcAudioCodecs.subtracting(avKitAudioCodecs)

    /// Containers VLC opens that AVKit cannot. The VLC-tier DirectPlay entries
    /// in the device profile use this set.
    public static let softwareContainers: Set<Container> =
        vlcContainers.subtracting(avKitContainers)
}

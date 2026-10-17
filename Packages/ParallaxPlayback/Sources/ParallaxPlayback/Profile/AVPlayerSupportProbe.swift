import CoreMedia
import ParallaxCore

/// Asks the system what AVPlayer plays on this device, one representative MIME type per
/// codec. The system calls arrive as parameters so the app target supplies the real ones
/// (`AVURLAsset.isPlayableExtendedMIMEType`, `AVURLAsset.audiovisualMIMETypes()`,
/// `VTIsHardwareDecodeSupported`) and tests supply literals.
///
/// The answers are codec-family level: the MIME check says yes to profiles AVPlayer cannot
/// decode (H.264 High 10, AV1 12-bit), so profile and bit-depth gates stay in the Jellyfin
/// device profile's CodecProfile conditions.
public enum AVPlayerSupportProbe {
    public static func probe(
        isPlayable: (String) -> Bool,
        mimeTypes: Set<String>,
        decodesInHardware: (CMVideoCodecType) -> Bool
    ) -> AVPlayerSupport {
        // Codecs are asked under MP4 only, and the answer stands for MOV, which carries the
        // same codecs. Video past H.264 also needs a hardware decoder: the MIME check speaks
        // for the format, not the silicon. Every Apple device decodes H.264 in hardware, so
        // asking would only fail where VideoToolbox has no decoders at all, the Simulator.
        // HLS is AVPlayer's own streaming format, so it is not asked.
        AVPlayerSupport(
            containers: Set(Container.allCases.filter { container in
                mimeType(container).map(mimeTypes.contains) ?? false
            }).union([.hls]),
            videoCodecs: Set(VideoCodec.allCases.filter { codec in
                guard let (codecs, decoder) = mp4Spelling(codec) else { return false }
                return isPlayable("video/mp4; codecs=\"\(codecs)\"") && (decoder.map(decodesInHardware) ?? true)
            }),
            audioCodecs: Set(AudioCodec.allCases.filter { codec in
                isPlayable("audio/mp4; codecs=\"\(mp4Spelling(codec))\"")
            })
        )
    }

    /// File containers AVPlayer opens directly; the rest are VLC's alone.
    private static func mimeType(_ container: Container) -> String? {
        switch container {
        case .mp4: "video/mp4"
        case .mov: "video/quicktime"
        case .hls, .mkv, .webm, .ts, .flac, .mp3, .avi, .asf: nil
        }
    }

    /// RFC 6381 `codecs` value and the hardware decoder it needs, nil for H.264. VC-1 and
    /// MPEG-2 map to nil: AVPlayer never plays them.
    private static func mp4Spelling(_ codec: VideoCodec) -> (codecs: String, decoder: CMVideoCodecType?)? {
        switch codec {
        case .h264: ("avc1.640028", nil)
        case .hevc: ("hvc1.2.4.L153.B0", kCMVideoCodecType_HEVC)
        case .av1: ("av01.0.13M.10", kCMVideoCodecType_AV1)
        case .vp9: ("vp09.00.40.08", kCMVideoCodecType_VP9)
        case .vc1, .mpeg2video: nil
        }
    }

    private static func mp4Spelling(_ codec: AudioCodec) -> String {
        switch codec {
        case .aac: "mp4a.40.2"
        case .ac3: "ac-3"
        case .eac3: "ec-3"
        case .mp3: "mp4a.6B"
        case .flac: "fLaC"
        case .opus: "Opus"
        case .dts: "dtsc"
        case .trueHD: "mlpa"
        }
    }
}

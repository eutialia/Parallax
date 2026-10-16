import AVFoundation
import CoreMedia
import Testing
import ParallaxCore
import ParallaxPlayback

@Suite("AVPlayerSupportProbe")
struct AVPlayerSupportProbeTests {

    struct Device: Sendable, CustomTestStringConvertible {
        let name: String
        let playable: Set<String>
        let mimeTypes: Set<String>
        let hardware: Set<CMVideoCodecType>
        let support: AVPlayerSupport
        var testDescription: String { name }
    }

    static let m4Playable: Set<String> = [
        #"video/mp4; codecs="avc1.640028""#,
        #"video/mp4; codecs="hvc1.2.4.L153.B0""#,
        #"video/mp4; codecs="av01.0.13M.10""#,
        #"audio/mp4; codecs="mp4a.40.2""#,
        #"audio/mp4; codecs="ac-3""#,
        #"audio/mp4; codecs="ec-3""#,
        #"audio/mp4; codecs="fLaC""#,
        #"audio/mp4; codecs="Opus""#,
    ]
    static let systemMIMETypes: Set<String> = [
        "video/mp4", "video/quicktime", "application/vnd.apple.mpegurl", "audio/mpeg", "audio/x-flac",
    ]

    static let devices: [Device] = [
        Device(
            name: "AV1 hardware: the MIME answers stand",
            playable: m4Playable,
            mimeTypes: systemMIMETypes,
            hardware: [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_AV1],
            support: AVPlayerSupport(
                containers: [.mp4, .mov, .hls],
                videoCodecs: [.h264, .hevc, .av1],
                audioCodecs: [.aac, .ac3, .eac3, .flac, .opus]
            )
        ),
        Device(
            name: "no AV1 hardware: av1 drops though the MIME check says yes",
            playable: m4Playable,
            mimeTypes: systemMIMETypes,
            hardware: [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC],
            support: AVPlayerSupport(
                containers: [.mp4, .mov, .hls],
                videoCodecs: [.h264, .hevc],
                audioCodecs: [.aac, .ac3, .eac3, .flac, .opus]
            )
        ),
        Device(
            name: "hardware without a MIME yes: vp9 stays out; hls needs no MIME type",
            playable: [#"video/mp4; codecs="avc1.640028""#, #"audio/mp4; codecs="mp4a.40.2""#],
            mimeTypes: ["video/mp4"],
            hardware: [kCMVideoCodecType_H264, kCMVideoCodecType_VP9],
            support: AVPlayerSupport(containers: [.mp4, .hls], videoCodecs: [.h264], audioCodecs: [.aac])
        ),
        Device(
            name: "no hardware decoders at all, the Simulator: h264 still counts",
            playable: m4Playable,
            mimeTypes: systemMIMETypes,
            hardware: [],
            support: AVPlayerSupport(
                containers: [.mp4, .mov, .hls],
                videoCodecs: [.h264],
                audioCodecs: [.aac, .ac3, .eac3, .flac, .opus]
            )
        ),
    ]

    @Test("a codec counts when the system says yes; video past h264 also needs hardware", arguments: devices)
    func probe(device: Device) {
        let support = AVPlayerSupportProbe.probe(
            isPlayable: { device.playable.contains($0) },
            mimeTypes: device.mimeTypes,
            decodesInHardware: { device.hardware.contains($0) }
        )
        #expect(support == device.support)
    }

    /// VC-1 and MPEG-2 have no MP4 spelling to ask about, and MKV/WebM/TS/AVI are not
    /// AVPlayer containers, whatever the system says.
    @Test("a system that says yes to everything still yields only AVPlayer's formats")
    func yesToEverything() {
        let support = AVPlayerSupportProbe.probe(
            isPlayable: { _ in true },
            mimeTypes: Self.systemMIMETypes.union(["video/x-matroska", "video/webm", "video/mp2t", "video/avi"]),
            decodesInHardware: { _ in true }
        )
        #expect(support == AVPlayerSupport(
            containers: [.mp4, .mov, .hls],
            videoCodecs: [.h264, .hevc, .av1, .vp9],
            audioCodecs: Set(AudioCodec.allCases)
        ))
    }

    /// The probe's MIME strings against the host's real AVFoundation: a misspelled codec
    /// string fails here and nowhere else. Hardware is stubbed because a CI VM exposes no
    /// decoders; the hardware gate is covered above.
    @Test("the host's AVFoundation recognizes the probe's MIME strings")
    func hostSystem() {
        let support = AVPlayerSupportProbe.probe(
            isPlayable: AVURLAsset.isPlayableExtendedMIMEType,
            mimeTypes: Set(AVURLAsset.audiovisualMIMETypes()),
            decodesInHardware: { _ in true }
        )
        #expect(support.containers.isSuperset(of: [.mp4, .mov, .hls]))
        #expect(support.videoCodecs.isSuperset(of: [.h264, .hevc]))
        #expect(support.audioCodecs.isSuperset(of: [.aac, .ac3, .eac3, .flac, .opus]))
        #expect(support.audioCodecs.isDisjoint(with: [.mp3, .dts, .trueHD]))
    }
}

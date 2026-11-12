import AetherLibavcodec
import AetherLibavutil
import Foundation

/// A stream's codec configuration as libavformat read it, kept whole so the MP4 muxer writes the
/// sample entry from the same record the demuxer parsed.
///
/// Sendable because the copy is never written after `init`.
final class CodecParameters: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<AVCodecParameters>

    init?(copying source: UnsafePointer<AVCodecParameters>) {
        guard let copy = avcodec_parameters_alloc() else { return nil }
        guard avcodec_parameters_copy(copy, source) >= 0 else {
            var copy: UnsafeMutablePointer<AVCodecParameters>? = copy
            avcodec_parameters_free(&copy)
            return nil
        }
        pointer = copy
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVCodecParameters>? = pointer
        avcodec_parameters_free(&pointer)
    }

    /// libavcodec's name for the codec: "h264", "aac", "dts".
    var codecName: String { String(cString: avcodec_get_name(pointer.pointee.codec_id)) }

    var pixelSize: (width: Int, height: Int) { (Int(pointer.pointee.width), Int(pointer.pointee.height)) }
    /// How many frames a picture can be stored ahead of the ones that display before it.
    var reorderDepth: Int { Int(pointer.pointee.video_delay) }
    var sampleRate: Int { Int(pointer.pointee.sample_rate) }
    /// Zero when the frame length is not known.
    var samplesPerFrame: Int {
        // libavformat leaves AC-3 at zero. A frame is always six blocks of 256 samples.
        pointer.pointee.codec_id == AV_CODEC_ID_AC3 ? 1536 : Int(pointer.pointee.frame_size)
    }

    /// The profile in the Dolby Vision record the container carries for the stream. Nil for a
    /// stream with no such record.
    var dolbyVisionProfile: Int? {
        let record = av_packet_side_data_get(
            pointer.pointee.coded_side_data, pointer.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
        return record?.pointee.data.map {
            Int(UnsafeRawPointer($0).load(as: AVDOVIDecoderConfigurationRecord.self).dv_profile)
        }
    }

    /// The codec and its profile as libavcodec names them, and the Dolby Vision profile when
    /// there is one: "h264 High 10", "dts DTS-HD MA", "hevc Main 10, Dolby Vision profile 5".
    var displayName: String {
        let profile = avcodec_profile_name(pointer.pointee.codec_id, pointer.pointee.profile)
            .map { " " + String(cString: $0) } ?? ""
        let dolbyVision = dolbyVisionProfile.map { ", Dolby Vision profile \($0)" } ?? ""
        return codecName + profile + dolbyVision
    }

    /// The RFC 6381 string a playlist's `CODECS` carries, which starts with the MP4 sample entry
    /// the codec is stored under. Nil for a codec or profile the bridge does not deliver, which
    /// is what makes the plan refuse the file.
    var playlistCodec: String? {
        let extradata = UnsafeBufferPointer(start: pointer.pointee.extradata, count: Int(pointer.pointee.extradata_size))
        switch pointer.pointee.codec_id {
        case AV_CODEC_ID_H264:
            // An `avcC` record: version, then the profile, constraint and level bytes. Baseline,
            // Main and High are the profiles Apple's decoders take.
            guard extradata.count >= 4, extradata[0] == 1, [66, 77, 100].contains(extradata[1]) else { return nil }
            return String(format: "avc1.%02x%02x%02x", extradata[1], extradata[2], extradata[3])
        case AV_CODEC_ID_HEVC:
            // An `hvcC` record: version, a byte of profile space, tier and profile, four bytes
            // of compatibility flags, six of constraint flags, then the level.
            guard extradata.count >= 13, extradata[0] == 1 else { return nil }
            let space = extradata[1] >> 6, isHighTier = extradata[1] & 0x20 != 0, profile = extradata[1] & 0x1f
            // Main and Main 10. Dolby Vision profile 5 calls itself Main 10 and is not: its
            // picture is in Dolby's own color space, and played as plain HEVC it shows green
            // and purple.
            guard space == 0, profile == 1 || profile == 2, dolbyVisionProfile != 5 else { return nil }
            // The string carries the compatibility flags with their bits in reverse order, and
            // the constraint bytes up to the last that is not zero.
            let compatibility = extradata[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let reversed = (0..<32).reduce(UInt32(0)) { $0 | (compatibility >> $1 & 1) << (31 - $1) }
            let constraints = extradata[6...11].reversed().drop { $0 == 0 }.reversed()
                .map { "." + String($0, radix: 16, uppercase: true) }.joined()
            return "hvc1.\(profile).\(String(reversed, radix: 16, uppercase: true))"
                + ".\(isHighTier ? "H" : "L")\(extradata[12])\(constraints)"
        case AV_CODEC_ID_AAC:
            // libavcodec numbers AAC profiles one below the MPEG-4 audio object type: LC is 1,
            // HE is 4 and HE v2 is 28.
            return [1, 4, 28].contains(pointer.pointee.profile) ? "mp4a.40.\(pointer.pointee.profile + 1)" : nil
        case AV_CODEC_ID_AC3:
            return "ac-3"
        default:
            return nil
        }
    }
}

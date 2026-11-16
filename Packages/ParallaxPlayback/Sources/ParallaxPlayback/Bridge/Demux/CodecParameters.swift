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
    /// The HLS name of the video's transfer function: "PQ" for HDR10 and Dolby Vision over PQ, "HLG",
    /// and "SDR" for everything else. AVPlayer reads the function from the video itself and
    /// fails an item whose playlist says otherwise.
    var videoRange: String {
        switch pointer.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: "PQ"
        case AVCOL_TRC_ARIB_STD_B67: "HLG"
        default: "SDR"
        }
    }

    /// The stream says its pictures are stored as fields. A stream that says nothing is taken
    /// for progressive.
    var isInterlaced: Bool {
        switch pointer.pointee.field_order {
        case AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT: true
        default: false
        }
    }

    /// AAC the container gave no configuration record: each frame is behind an ADTS header
    /// that describes it, as a transport stream stores it.
    var hasADTSHeaders: Bool {
        pointer.pointee.codec_id == AV_CODEC_ID_AAC && pointer.pointee.extradata_size == 0
    }

    var channelCount: Int { Int(pointer.pointee.ch_layout.nb_channels) }

    /// What a playlist's `CHANNELS` says: the channel count, or "16/JOC" for E-AC-3 that
    /// carries Dolby Atmos objects. libavcodec tells Atmos from the first frames it decodes
    /// while the file opens.
    var playlistChannels: String {
        pointer.pointee.codec_id == AV_CODEC_ID_EAC3 && pointer.pointee.profile == AV_PROFILE_EAC3_DDP_ATMOS
            ? "16/JOC" : "\(channelCount)"
    }

    /// The samples one frame holds, which is the same for every frame of a stream. The
    /// container records it for AAC. For the rest libavcodec's parser reads it from the header
    /// of `frame`, one whole frame of the stream. Zero when neither knows.
    func samplesPerFrame(readingHeaderOf frame: Data) -> Int {
        if pointer.pointee.frame_size > 0 { return Int(pointer.pointee.frame_size) }
        guard let parser = av_parser_init(Int32(pointer.pointee.codec_id.rawValue)) else { return 0 }
        defer { av_parser_close(parser) }
        var context = avcodec_alloc_context3(nil)
        defer { avcodec_free_context(&context) }
        guard let context, avcodec_parameters_to_context(context, pointer) >= 0 else { return 0 }
        parser.pointee.flags |= PARSER_FLAG_COMPLETE_FRAMES
        // The parser reads past the end of its input by up to this much.
        let padded = frame + Data(count: Int(AV_INPUT_BUFFER_PADDING_SIZE))
        var parsed: UnsafeMutablePointer<UInt8>?
        var parsedSize: Int32 = 0
        padded.withUnsafeBytes {
            _ = av_parser_parse2(
                parser, context, &parsed, &parsedSize, $0.bindMemory(to: UInt8.self).baseAddress,
                Int32(frame.count), Int64.min, Int64.min, 0)
        }
        return Int(parser.pointee.duration)
    }

    /// The frames of `samplesPerFrame` one MP4 sample holds. An E-AC-3 sample holds six blocks
    /// of 256 (ETSI TS 102 366, Annex F), and libavformat's muxer joins shorter frames until it
    /// has them. Every other codec, one.
    func framesPerSample(of samplesPerFrame: Int) -> Int {
        pointer.pointee.codec_id == AV_CODEC_ID_EAC3 && (1..<Self.blocksPerSample * 256).contains(samplesPerFrame)
            ? Self.blocksPerSample * 256 / samplesPerFrame : 1
    }

    /// The most frames one MP4 sample holds: E-AC-3 of one block a frame.
    static let mostFramesPerSample = blocksPerSample
    private static let blocksPerSample = 6

    /// The Dolby Vision record the container carries for the stream. Nil for a stream with none.
    private var dolbyVisionRecord: AVDOVIDecoderConfigurationRecord? {
        let record = av_packet_side_data_get(
            pointer.pointee.coded_side_data, pointer.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
        return record?.pointee.data.map { UnsafeRawPointer($0).load(as: AVDOVIDecoderConfigurationRecord.self) }
    }

    var dolbyVisionProfile: Int? { dolbyVisionRecord.map { Int($0.dv_profile) } }

    /// The Dolby Vision layer a playlist's `SUPPLEMENTAL-CODECS` names over the HEVC its
    /// `CODECS` does: "dvh1.08.06/db1p" for profile 8.1 at level 6, whose base layer is HDR10, and
    /// "dvh1.08.06/db4h" for 8.4, whose base is HLG. Nil for every other stream, which plays
    /// as its HEVC base: Apple's players take no other profile that has one.
    var dolbyVisionCodec: String? {
        guard pointer.pointee.codec_id == AV_CODEC_ID_HEVC, let record = dolbyVisionRecord, record.dv_profile == 8,
              record.rpu_present_flag == 1
        else { return nil }
        let brand = switch record.dv_bl_signal_compatibility_id {
        case 1: "db1p"
        case 4: "db4h"
        default: nil as String?
        }
        return brand.map { String(format: "dvh1.08.%02d/%@", record.dv_level, $0) }
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
        switch pointer.pointee.codec_id {
        case AV_CODEC_ID_H264:
            // Baseline, Main and High are the profiles every Apple decoder takes, and High 10
            // some.
            guard let level = h264ProfileLevelID, [66, 77, 100, 110].contains(level[0]) else { return nil }
            return String(format: "avc1.%02x%02x%02x", level[0], level[1], level[2])
        case AV_CODEC_ID_HEVC:
            guard let level = hevcProfileTierLevel else { return nil }
            let space = level[0] >> 6, isHighTier = level[0] & 0x20 != 0, profile = level[0] & 0x1f
            // Main and Main 10. Dolby Vision profile 5 calls itself Main 10 and is not: its
            // picture is in Dolby's own color space, and played as plain HEVC it shows green
            // and purple.
            guard space == 0, profile == 1 || profile == 2, dolbyVisionProfile != 5 else { return nil }
            // The string carries the compatibility flags with their bits in reverse order, and
            // the constraint bytes up to the last that is not zero.
            let compatibility = level[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let reversed = (0..<32).reduce(UInt32(0)) { $0 | (compatibility >> $1 & 1) << (31 - $1) }
            let constraints = level[5...10].reversed().drop { $0 == 0 }.reversed()
                .map { "." + String($0, radix: 16, uppercase: true) }.joined()
            return "hvc1.\(profile).\(String(reversed, radix: 16, uppercase: true))"
                + ".\(isHighTier ? "H" : "L")\(level[11])\(constraints)"
        case AV_CODEC_ID_AAC:
            // libavcodec numbers AAC profiles one below the MPEG-4 audio object type: LC is 1,
            // HE is 4 and HE v2 is 28.
            return [1, 4, 28].contains(pointer.pointee.profile) ? "mp4a.40.\(pointer.pointee.profile + 1)" : nil
        case AV_CODEC_ID_AC3:
            return "ac-3"
        case AV_CODEC_ID_EAC3:
            return "ec-3"
        case AV_CODEC_ID_FLAC:
            return "fLaC"
        case AV_CODEC_ID_OPUS:
            return "Opus"
        case AV_CODEC_ID_AV1:
            // An `av1C` record: a marker and version byte, then the profile and level, then the
            // tier and the bits that give the depth. Main is the profile Apple's decoders take.
            let extradata = configuration
            guard extradata.count >= 4, extradata[0] == 0x81 else { return nil }
            let profile = extradata[1] >> 5, level = extradata[1] & 0x1f
            guard profile == 0 else { return nil }
            let isHighTier = extradata[2] & 0x80 != 0
            let depth = extradata[2] & 0x40 == 0 ? 8 : extradata[2] & 0x20 == 0 ? 10 : 12
            return String(format: "av01.%d.%02d%@.%02d", profile, level, isHighTier ? "H" : "M", depth)
        default:
            return nil
        }
    }

    /// The codec's configuration as the container gives it. For H.264 and HEVC that is an MP4
    /// record, which starts with a version byte of one, or the stream's own parameter sets,
    /// each behind a start code, as a transport stream carries them.
    private var configuration: [UInt8] {
        Array(UnsafeBufferPointer(start: pointer.pointee.extradata, count: Int(pointer.pointee.extradata_size)))
    }

    /// H.264's profile, constraint and level bytes, which an `avcC` record and a sequence
    /// parameter set both hold in that order.
    private var h264ProfileLevelID: [UInt8]? {
        let configuration = configuration
        let level = configuration.first == 1
            ? configuration.dropFirst()
            : Self.parameterSet(in: configuration, headerLength: 1) { $0 & 0x1f == 7 }?[...]
        return level.flatMap { $0.count >= 3 ? Array($0.prefix(3)) : nil }
    }

    /// HEVC's twelve bytes of profile, tier and level, which an `hvcC` record and a sequence
    /// parameter set both hold whole: a byte of profile space, tier and profile, four of
    /// compatibility flags, six of constraint flags, then the level.
    private var hevcProfileTierLevel: [UInt8]? {
        let configuration = configuration
        // The parameter set has a byte of its own first: the set it refers to and its layers.
        let level = configuration.first == 1
            ? configuration.dropFirst()
            : Self.parameterSet(in: configuration, headerLength: 2) { $0 >> 1 & 0x3f == 33 }?.dropFirst()
        return level.flatMap { $0.count >= 12 ? Array($0.prefix(12)) : nil }
    }

    /// The first unit among start-code-prefixed `units` whose first byte `isWanted`, after its
    /// header and without the `03` bytes the encoder put in to keep start codes out of it.
    private static func parameterSet(
        in units: [UInt8], headerLength: Int, where isWanted: (UInt8) -> Bool
    ) -> [UInt8]? {
        let startCode: [UInt8] = [0, 0, 1]
        let starts = units.indices.dropLast(startCode.count).filter { units[$0...].starts(with: startCode) }
        return zip(starts, starts.dropFirst() + [units.endIndex])
            .map { units[($0 + startCode.count)..<$1] }
            .first { $0.first.map(isWanted) == true }
            .map { unit in
                unit.dropFirst(headerLength).reduce(into: (bytes: [UInt8](), zeros: 0)) { payload, byte in
                    if byte != 3 || payload.zeros < 2 { payload.bytes.append(byte) }
                    payload.zeros = byte == 0 ? payload.zeros + 1 : 0
                }.bytes
            }
    }
}

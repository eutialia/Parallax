import AetherLibavcodec
import AetherLibavutil
import Foundation

/// Frames of silence a copied audio track starts with, in the track's own codec, from the file's
/// first picture to the track's first frame. AVPlayer opens an HLS presentation where its audio
/// starts, and would not show the pictures before it.
struct LeadingSilence: Sendable {
    /// Ticks on the track's clock: where each frame starts.
    let starts: [Int64]
    let frameLength: Int64
    let frames: [Data]

    /// Nil when the track's first frame is no later than `firstPicture`, and for a codec this
    /// build makes no silence in. Ticks on the track's clock; `frameLength` is the stream's.
    init?(of parameters: CodecParameters, from firstPicture: Int64, to firstFrame: Int64, frameLength: Int64) {
        let starts = Self.starts(from: firstPicture, to: firstFrame, frameLength: frameLength)
        guard !starts.isEmpty, let frames = Self.encoded(starts.count, like: parameters, frameLength: frameLength)
        else { return nil }
        self.starts = starts
        self.frameLength = frameLength
        self.frames = frames
    }

    /// Where whole frames start that run on from `firstPicture` or before it and end at
    /// `firstFrame`, none of them before zero: a fragment's time cannot be.
    static func starts(from firstPicture: Int64, to firstFrame: Int64, frameLength: Int64) -> [Int64] {
        let covering = (firstFrame - firstPicture + frameLength - 1) / frameLength
        let count = firstFrame > firstPicture ? min(covering, firstFrame / frameLength) : 0
        return (0..<count).map { firstFrame - (count - $0) * frameLength }
    }

    /// The copied codecs whose silence was heard to play in front of the stream's own frames:
    /// AAC-LC, AC-3 and E-AC-3. libavcodec has no Opus encoder, and its AAC encoder writes no
    /// HE-AAC, whose frames are then of another length.
    private static let encodedCodecs: Set<UInt32> = [AV_CODEC_ID_AAC.rawValue, AV_CODEC_ID_AC3.rawValue, AV_CODEC_ID_EAC3.rawValue]

    /// `count` frames of `frameLength` sample frames, for `parameters`' rate and channels.
    private static func encoded(_ count: Int, like parameters: CodecParameters, frameLength: Int64) -> [Data]? {
        let source = parameters.pointer.pointee
        guard encodedCodecs.contains(source.codec_id.rawValue),
              source.codec_id != AV_CODEC_ID_AAC || source.profile == AV_PROFILE_AAC_LOW,
              let codec = avcodec_find_encoder(source.codec_id)
        else { return nil }
        var context = avcodec_alloc_context3(codec)
        var frame = av_frame_alloc(), packet = av_packet_alloc()
        defer {
            avcodec_free_context(&context)
            av_frame_free(&frame)
            av_packet_free(&packet)
        }
        guard let encoder = context, let frame, let packet else { return nil }
        encoder.pointee.sample_rate = source.sample_rate
        encoder.pointee.time_base = AVRational(num: 1, den: source.sample_rate)
        if source.bit_rate > 0 { encoder.pointee.bit_rate = source.bit_rate }
        var layout = source.ch_layout
        var formats: UnsafeRawPointer?
        var formatCount: Int32 = 0
        guard av_channel_layout_copy(&encoder.pointee.ch_layout, &layout) >= 0,
              avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &formats, &formatCount) >= 0,
              let formats, formatCount > 0
        else { return nil }
        encoder.pointee.sample_fmt = formats.assumingMemoryBound(to: AVSampleFormat.self).pointee
        guard avcodec_open2(encoder, codec, nil) >= 0, Int64(encoder.pointee.frame_size) == frameLength else { return nil }

        frame.pointee.nb_samples = encoder.pointee.frame_size
        frame.pointee.format = encoder.pointee.sample_fmt.rawValue
        frame.pointee.sample_rate = encoder.pointee.sample_rate
        guard av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout) >= 0,
              av_frame_get_buffer(frame, 0) >= 0
        else { return nil }
        av_samples_set_silence(
            frame.pointee.extended_data, 0, frame.pointee.nb_samples, encoder.pointee.ch_layout.nb_channels,
            encoder.pointee.sample_fmt)

        var frames: [Data] = []
        // An encoder may hold back its first frames, so it is fed until it gives `count`.
        for index in 0..<(count + 8) where frames.count < count {
            frame.pointee.pts = Int64(index) * frameLength
            guard avcodec_send_frame(encoder, frame) >= 0 else { return nil }
            while frames.count < count, avcodec_receive_packet(encoder, packet) >= 0 {
                frames.append(Data(bytes: packet.pointee.data, count: Int(packet.pointee.size)))
                av_packet_unref(packet)
            }
        }
        guard frames.count == count else { return nil }
        return parameters.hasADTSHeaders ? frames.map { adts($0, like: source) } : frames
    }

    /// `frame` behind the ADTS header that describes it, as each of a transport stream's AAC
    /// frames is (ISO/IEC 13818-7, 6.2).
    private static func adts(_ frame: Data, like source: AVCodecParameters) -> Data {
        let rates: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let rate = UInt8(rates.firstIndex(of: source.sample_rate) ?? 15)
        let channels = UInt8(source.ch_layout.nb_channels == 8 ? 7 : source.ch_layout.nb_channels)
        let length = frame.count + 7
        let header: [UInt8] = [
            // Sync word, MPEG-4, no CRC; then AAC-LC, the rate's index and the channels.
            0xFF, 0xF1, 1 << 6 | rate << 2 | channels >> 2,
            (channels & 3) << 6 | UInt8(length >> 11), UInt8(length >> 3 & 0xFF),
            // The buffer's fullness marked as variable, and one block of samples.
            UInt8(length & 7) << 5 | 0x1F, 0xFC,
        ]
        return Data(header) + frame
    }
}

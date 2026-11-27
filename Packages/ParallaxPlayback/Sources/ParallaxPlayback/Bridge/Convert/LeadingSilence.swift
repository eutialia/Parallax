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

    /// `length` ticks of frames that end at `firstFrame`, on the track's clock: `frameLength` is
    /// the stream's. Nil for no length, and for a codec this build makes no silence in.
    init?(of parameters: CodecParameters, lasting length: Int64, until firstFrame: Int64, frameLength: Int64) {
        guard length > 0, let frames = Self.encoded(Int(length / frameLength), like: parameters, frameLength: frameLength)
        else { return nil }
        starts = Array(stride(from: firstFrame - length, to: firstFrame, by: Int(frameLength)))
        self.frameLength = frameLength
        self.frames = frames
    }

    /// Ticks at `sampleRate`: the whole frames that reach from the track's first frame, at
    /// `firstFrame`, back to `firstPicture` or before it. Both are nanoseconds. Zero when the
    /// track starts with the picture.
    static func length(from firstPicture: Int64, to firstFrame: Int64, sampleRate: Int64, frameLength: Int64) -> Int64 {
        guard firstFrame > firstPicture else { return 0 }
        // The track's grid would move the picture to the start of a frame, which may be after it.
        let lead = Int64((Int128(firstFrame - firstPicture) * Int128(sampleRate) + 999_999_999) / 1_000_000_000)
        return (lead + frameLength - 1) / frameLength * frameLength
    }

    /// `count` frames of `frameLength` sample frames, for `parameters`' rate and channels. Opus
    /// is written by hand: this build has no Opus encoder.
    private static func encoded(_ count: Int, like parameters: CodecParameters, frameLength: Int64) -> [Data]? {
        let source = parameters.pointer.pointee
        if source.codec_id == AV_CODEC_ID_OPUS {
            return opus(frameLength: frameLength, head: parameters.configuration).map { Array(repeating: $0, count: count) }
        }
        guard let setting = Encoding(source, frameLength: frameLength), let codec = avcodec_find_encoder(setting.codec)
        else { return nil }
        var context = avcodec_alloc_context3(codec)
        var frame = av_frame_alloc(), packet = av_packet_alloc()
        defer {
            avcodec_free_context(&context)
            av_frame_free(&frame)
            av_packet_free(&packet)
        }
        guard let encoder = context, let frame, let packet else { return nil }
        encoder.pointee.sample_rate = setting.sampleRate
        encoder.pointee.time_base = AVRational(num: 1, den: setting.sampleRate)
        encoder.pointee.bits_per_raw_sample = setting.bitsPerSample
        encoder.pointee.frame_size = setting.requestedFrameSize
        if source.bit_rate > 0 { encoder.pointee.bit_rate = source.bit_rate }
        var layout = source.ch_layout
        if setting.channels == layout.nb_channels {
            guard av_channel_layout_copy(&encoder.pointee.ch_layout, &layout) >= 0 else { return nil }
        } else {
            av_channel_layout_default(&encoder.pointee.ch_layout, setting.channels)
        }
        var formats: UnsafeRawPointer?
        var formatCount: Int32 = 0
        guard avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &formats, &formatCount) >= 0,
              let formats, formatCount > 0,
              // The narrowest that holds the stream's depth: an encoder given wider samples
              // writes frames of a deeper stream than the track's.
              let format = UnsafeBufferPointer(start: formats.assumingMemoryBound(to: AVSampleFormat.self), count: Int(formatCount))
                .filter({ av_get_bytes_per_sample($0) * 8 >= setting.bitsPerSample })
                .min(by: { av_get_bytes_per_sample($0) < av_get_bytes_per_sample($1) })
        else { return nil }
        encoder.pointee.sample_fmt = format
        // A frame of another length would move the track, and so would an E-AC-3 frame the
        // muxer joins with others, which has no sample of its own to be placed in.
        guard avcodec_open2(encoder, codec, nil) >= 0,
              Int64(encoder.pointee.frame_size) * setting.samplesPerCodedSample == frameLength
        else { return nil }

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
            frame.pointee.pts = Int64(index) * Int64(encoder.pointee.frame_size)
            guard avcodec_send_frame(encoder, frame) >= 0 else { return nil }
            while frames.count < count, avcodec_receive_packet(encoder, packet) >= 0 {
                frames.append(Data(bytes: packet.pointee.data, count: Int(packet.pointee.size)))
                av_packet_unref(packet)
            }
        }
        guard frames.count == count else { return nil }
        return parameters.hasADTSHeaders
            ? frames.map { adts($0, rate: setting.sampleRate, channels: setting.channels) } : frames
    }

    /// How this build's encoder makes a copied track's silence.
    private struct Encoding {
        let codec: AVCodecID
        let sampleRate: Int32
        let channels: Int32
        let bitsPerSample: Int32
        /// Zero leaves the encoder its own frame length.
        let requestedFrameSize: Int32
        /// What one of the encoder's samples is on the track's clock: two for HE-AAC.
        let samplesPerCodedSample: Int64

        init?(_ source: AVCodecParameters, frameLength: Int64) {
            let bits = max(16, source.bits_per_raw_sample)
            switch (source.codec_id, source.profile) {
            case (AV_CODEC_ID_AAC, AV_PROFILE_AAC_LOW), (AV_CODEC_ID_AC3, _), (AV_CODEC_ID_EAC3, _):
                self.init(source.codec_id, source, bits: 16)
            // HE-AAC is AAC-LC at half the rate, the higher band coded on top, and v2 codes
            // stereo as mono with how to spread it. A frame with nothing on top decodes as the
            // band below: silence.
            case (AV_CODEC_ID_AAC, AV_PROFILE_AAC_HE), (AV_CODEC_ID_AAC, AV_PROFILE_AAC_HE_V2):
                self.init(
                    AV_CODEC_ID_AAC, source, bits: 16, rate: source.sample_rate / 2,
                    channels: source.profile == AV_PROFILE_AAC_HE_V2 ? 1 : source.ch_layout.nb_channels,
                    samplesPerCodedSample: 2)
            // Lossless frames of the stream's own length and depth.
            case (AV_CODEC_ID_FLAC, _), (AV_CODEC_ID_ALAC, _):
                self.init(source.codec_id, source, bits: bits, frameSize: Int32(frameLength))
            default:
                return nil
            }
        }

        private init(
            _ codec: AVCodecID, _ source: AVCodecParameters, bits: Int32, rate: Int32? = nil, channels: Int32? = nil,
            frameSize: Int32 = 0, samplesPerCodedSample: Int64 = 1
        ) {
            self.codec = codec
            sampleRate = rate ?? source.sample_rate
            self.channels = channels ?? source.ch_layout.nb_channels
            bitsPerSample = bits
            requestedFrameSize = frameSize
            self.samplesPerCodedSample = samplesPerCodedSample
        }
    }

    /// A silent Opus packet of `frameLength` at 48 kHz (RFC 6716, 3.1): a CELT-only frame at
    /// full band, whose two bytes decode as its silence flag. A stream of several Opus streams
    /// (RFC 7845, 5.1.1) carries one per stream, each but the last with its length in front.
    /// Nil for a length no single frame has.
    private static func opus(frameLength: Int64, head bytes: [UInt8]) -> Data? {
        let configs: [Int64: UInt8] = [120: 28, 240: 29, 480: 30, 960: 31]
        guard let config = configs[frameLength] else { return nil }
        let silence: [UInt8] = [config << 3, 0xFF, 0xFE]
        // An OpusHead: its mapping family at byte 18, and past family 0 the stream count at 19.
        let streams = bytes.count > 19 && bytes[18] != 0 ? Int(bytes[19]) : 1
        guard streams > 0 else { return nil }
        let delimited: [UInt8] = [silence[0], UInt8(silence.count - 1)] + silence.dropFirst()
        return Data(Array(repeating: delimited, count: streams - 1).joined() + silence)
    }

    /// `frame` behind the ADTS header that describes it, as each of a transport stream's AAC
    /// frames is (ISO/IEC 13818-7, 6.2). HE-AAC's header describes the AAC-LC below it.
    private static func adts(_ frame: Data, rate sampleRate: Int32, channels count: Int32) -> Data {
        let rates: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let rate = UInt8(rates.firstIndex(of: sampleRate) ?? 15)
        let channels = UInt8(count == 8 ? 7 : count)
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

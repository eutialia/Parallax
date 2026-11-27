import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CryptoKit
import Foundation

/// One sample of a media file as libavformat's own demuxer reads it from disk: the independent
/// reading the bridge's output is compared against.
struct ReadbackSample: Equatable {
    let stream: Int
    /// In `timescale` ticks.
    let presentation: Int64
    let decode: Int64
    /// In `timescale` ticks: until the next sample of its stream, or for the last, as long as
    /// the file says.
    let duration: Int64
    let timescale: Int64
    let isKeyframe: Bool
    let md5: String
}

struct ReadbackFailure: Error { let code: Int32 }

func readBackSamples(of bytes: Data, pathExtension: String) throws -> [ReadbackSample] {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    var context: UnsafeMutablePointer<AVFormatContext>?
    let opened = avformat_open_input(&context, url.path, nil, nil)
    guard opened >= 0, let context else { throw ReadbackFailure(code: opened) }
    defer {
        var context: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&context)
    }
    var packet = av_packet_alloc()
    defer { av_packet_free(&packet) }

    var samples: [ReadbackSample] = []
    while av_read_frame(context, packet) >= 0 {
        defer { av_packet_unref(packet) }
        guard let packet, let data = packet.pointee.data,
              let stream = context.pointee.streams[Int(packet.pointee.stream_index)]
        else { continue }
        samples.append(ReadbackSample(
            stream: Int(packet.pointee.stream_index),
            presentation: packet.pointee.pts, decode: packet.pointee.dts, duration: packet.pointee.duration,
            timescale: Int64(stream.pointee.time_base.den) / Int64(stream.pointee.time_base.num),
            isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
            md5: Insecure.MD5.hash(data: Data(bytes: data, count: Int(packet.pointee.size)))
                .map { String(format: "%02x", $0) }.joined()))
    }
    return samples
}

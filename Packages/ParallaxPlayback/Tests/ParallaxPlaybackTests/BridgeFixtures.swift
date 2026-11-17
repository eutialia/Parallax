import CoreVideo
import Foundation
import Testing
import ParallaxCore
@testable import ParallaxPlayback

/// The media bridge's fixtures, written by `scripts/gen-demux-fixtures.sh`.
enum BridgeFixture {
    /// A device with every decoder the bridge asks about, for tests not about the device.
    static let everyDecoder = AVPlayerSupport(
        containers: [.mp4, .mov, .hls], videoCodecs: Set(VideoCodec.allCases),
        audioCodecs: Set(AudioCodec.allCases), decodesH264High10: true)

    /// A device with no decoder for AV1 or 10-bit H.264, as an Apple TV 4K is.
    static let fewestDecoders = AVPlayerSupport(
        containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc],
        audioCodecs: Set(AudioCodec.allCases), decodesH264High10: false)

    /// Reads a numbered fixture's picture: 16 squares, 10 pixels wide, white for a set bit,
    /// lowest bit on the left.
    static func frameNumber(in buffer: CVPixelBuffer, rowsAboveTheMiddle: Int = 0) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return -1 }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let row = (CVPixelBufferGetHeightOfPlane(buffer, 0) / 2 - rowsAboveTheMiddle) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return (0..<16).reduce(0) { $0 | (luma[row + $1 * 10 + 5] > 128 ? 1 << $1 : 0) }
    }

    /// A fixture's bytes. `file` is "ts-h264.ts", or a Matroska fixture's name alone.
    static func data(_ file: String) throws -> Data {
        let parts = file.split(separator: ".", maxSplits: 1).map(String.init)
        return try data(parts[0], parts.count > 1 ? parts[1] : "mkv")
    }

    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: ext, subdirectory: "Fixtures/demux"))
        return try Data(contentsOf: url)
    }

    static func demuxer(_ file: String) async throws -> MediaDemuxer {
        try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data(file)))
    }

    /// ffprobe's md5 and keyframe flag of each packet of one stream, in file order.
    static func sourcePackets(_ file: String, stream: Int) throws -> [SourcePacket] {
        let name = String(file.prefix { $0 != "." })
        let rows = try #require(JSONSerialization.jsonObject(with: data(name, "packets.json")) as? [[Any]])
        return try rows.filter { $0[0] as? Int == stream }.map {
            SourcePacket(md5: try #require($0[4] as? String), isKeyframe: try #require($0[3] as? Bool))
        }
    }

    struct SourcePacket: Equatable {
        let md5: String
        let isKeyframe: Bool
    }
}

extension ServedResource {
    /// The whole body, as a client that reads it to the end gets it.
    func bytes() async throws -> Data {
        switch body {
        case .ranged(let reader):
            return try await reader.read(offset: 0, length: Int(try await reader.fileSize))
        case .streamed(let produce):
            let producer = produce()
            var body = Data()
            while let piece = try await producer.next() { body.append(piece) }
            return body
        }
    }
}

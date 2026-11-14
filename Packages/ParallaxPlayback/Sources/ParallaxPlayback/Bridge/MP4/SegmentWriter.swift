import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Writes one rendition's packets as fragmented MP4 through libavformat's muxer. Nothing is
/// decoded: every sample is the container's bytes.
enum SegmentWriter {
    enum Failure: Error, Equatable {
        case outOfMemory
        /// The span holds no packet of this rendition, so there is nothing to describe or play.
        case noSamples
        /// A sample the container gives no time. Guessing one would play it at the wrong moment.
        case untimedSample
        case muxer(code: Int32)
        /// The muxer took the samples and wrote no fragment.
        case noFragment
        /// A picture is shown earlier than one already given its decode time: the stream
        /// reorders further than the writer looks ahead.
        case reorderedTooFar
    }

    /// The `ftyp` and `moov` of the rendition, from its first packets: the muxer describes the
    /// track by its first MP4 sample, which takes the earliest of their presentation times as
    /// its decode time. The packets after it are not written: a few from a stream that reorders
    /// deeper than it declares would rank each other wrong, a decode time past its own
    /// presentation.
    static func initSegment(for rendition: Rendition, describedBy packets: [DemuxedPacket]) throws(Failure) -> Data {
        let writer = try FragmentWriter(rendition, limits: .whole)
        for packet in packets.prefix(writer.lookahead) { _ = try writer.append(packet) }
        return try writer.headerWithFirstSample()
    }

    /// The fragments of one segment holding `packets`, which are one span's packets of the
    /// rendition in file order. `FragmentWriter` writes them as the packets arrive.
    static func mediaSegment(
        for rendition: Rendition, packets: [DemuxedPacket], lastingUntil end: Int64? = nil,
        limits: FragmentLimits = .standard
    ) throws(Failure) -> Data {
        let writer = try FragmentWriter(rendition, lastingUntil: end, limits: limits)
        var segment = Data()
        for packet in packets {
            if let fragment = try writer.append(packet) { segment.append(fragment) }
        }
        segment.append(try writer.finish())
        return segment
    }

    static let flags = "frag_custom+delay_moov+default_base_moof+frag_discont"

    /// The offset of the first box of `type` at the top level, or among the children of the box
    /// at `parent`.
    static func offsetOfBox(_ type: String, in bytes: Data, inside parent: Int? = nil) -> Int? {
        let end = parent.map { $0 + bytes[bytes.startIndex + $0..<bytes.startIndex + $0 + 4].reduce(0) { $0 << 8 | Int($1) } }
            ?? bytes.count
        var offset = parent.map { $0 + 8 } ?? 0
        while offset + 8 <= min(end, bytes.count) {
            let header = bytes[bytes.startIndex + offset..<bytes.startIndex + offset + 8]
            let size = header.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            if String(decoding: header.suffix(4), as: UTF8.self) == type { return offset }
            guard size >= 8 else { return nil }
            offset += size
        }
        return nil
    }

    static func check(_ status: Int32) throws(Failure) {
        if status < 0 { throw .muxer(code: status) }
    }
}

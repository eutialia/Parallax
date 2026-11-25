import Foundation
import ParallaxCore

/// What a sample entry's own boxes say of the stream it describes.
extension MediaProbe {
    /// The profile of a video sample entry, read from the configuration record behind the 78
    /// bytes every visual sample entry starts with (`findAvcC`).
    static func videoProfile(_ data: Data, entry: BoxHeader) -> StreamProfile? {
        func secondByte(of type: String) -> UInt8? {
            guard entry.contentStart + 78 < entry.boxEnd,
                  let record = firstChildBox(data, type: type, in: entry.contentStart + 78..<entry.boxEnd),
                  record.contentStart + 1 < record.boxEnd else { return nil }
            return data[data.startIndex + record.contentStart + 1]
        }
        switch entry.type {
        case "avc1", "avc3": return secondByte(of: "avcC").map(StreamProfile.h264)
        case "av01": return secondByte(of: "av1C").map { .av1($0 >> 5) }
        default: return nil
        }
    }

    /// What an `mp4a` entry holds, by the object type in its `esds`: muxers store MP3 and DTS
    /// under `mp4a` too. AAC when the entry has no `esds` to say. Nil for an `esds` that does
    /// not parse, and for any other object type: AVFoundation reads AC-3, E-AC-3 and Opus only
    /// from entries of their own, and drops the track when they come in an `mp4a`.
    static func mp4aCodec(_ data: Data, entry: BoxHeader) -> AudioCodec? {
        guard let esds = elementaryStreamDescriptorBox(data, entry: entry) else { return .aac }
        switch objectType(data, esds: esds) {
        case let type? where aacObjectTypes.contains(type): return .aac
        case 0x69, 0x6B: return .mp3
        // As ffmpeg writes DTS in an MP4.
        case 0xA9: return .dts
        default: return nil
        }
    }

    /// MPEG-4 audio, and the three MPEG-2 AAC profiles.
    private static let aacObjectTypes: Set<UInt8> = [0x40, 0x66, 0x67, 0x68]

    /// An `mp4a` entry's `esds`, past the entry's fixed 28 bytes. A QuickTime sound
    /// description of version 1 or 2 keeps its `esds` inside a `wave` box, and is read as AAC.
    private static func elementaryStreamDescriptorBox(_ data: Data, entry: BoxHeader) -> BoxHeader? {
        let fixed = 28
        guard entry.type == "mp4a", entry.contentStart + fixed < entry.boxEnd,
              data[data.startIndex + entry.contentStart + 8] == 0, data[data.startIndex + entry.contentStart + 9] == 0
        else { return nil }
        return firstChildBox(data, type: "esds", in: entry.contentStart + fixed..<entry.boxEnd)
    }

    /// The object type in an `esds`'s descriptors (ISO/IEC 14496-1). Nil for descriptors that
    /// do not parse.
    private static func objectType(_ data: Data, esds: BoxHeader) -> UInt8? {
        var at = esds.contentStart + 4
        let end = min(esds.boxEnd, data.count)
        func byte() -> UInt8? {
            guard at < end else { return nil }
            defer { at += 1 }
            return data[data.startIndex + at]
        }
        // A descriptor's tag, past its size of one to four bytes.
        func descriptor() -> UInt8? {
            guard let tag = byte() else { return nil }
            for _ in 0..<4 {
                guard let size = byte() else { return nil }
                if size & 0x80 == 0 { break }
            }
            return tag
        }
        guard descriptor() == 0x03 else { return nil }
        // ES_ID, then flags for the fields that follow it: a stream it depends on, a URL of
        // a length byte and that many bytes, and an OCR stream.
        at += 2
        guard let flags = byte() else { return nil }
        if flags & 0x80 != 0 { at += 2 }
        if flags & 0x40 != 0 {
            guard let length = byte() else { return nil }
            at += Int(length)
        }
        if flags & 0x20 != 0 { at += 2 }
        guard descriptor() == 0x04 else { return nil }
        return byte()
    }
}

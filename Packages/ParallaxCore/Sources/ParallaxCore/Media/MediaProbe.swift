import Foundation

/// Result of a codec/container lookup where "the container simply doesn't carry
/// this stream" (`.none`) must be distinguishable from "carries it, but the
/// fourcc/codec id isn't one we recognize" (`.unknown`) — callers (`EngineSelector`)
/// route the latter to VLC rather than assuming AVKit compatibility.
public enum ProbedCodec<C: Sendable & Hashable>: Sendable, Hashable {
    case known(C)
    case unknown
    case none

    public var knownValue: C? {
        if case .known(let c) = self { return c }
        return nil
    }
}

public struct MediaProbeResult: Sendable, Equatable {
    public let container: Container?
    public let videoCodec: ProbedCodec<VideoCodec>
    public let audioCodec: ProbedCodec<AudioCodec>
    /// False when the MP4 box walk proves the file is truncated / still downloading
    /// (a box's declared extent overruns `fileSize`, or EOF arrives before any
    /// `moov` box). Non-MP4 containers always report true — VLC owns them as-is,
    /// truncation there isn't this probe's signal to detect.
    public let isComplete: Bool

    public init(
        container: Container?,
        videoCodec: ProbedCodec<VideoCodec>,
        audioCodec: ProbedCodec<AudioCodec>,
        isComplete: Bool
    ) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.isComplete = isComplete
    }
}

/// Sniffs container family from magic bytes and, for the MP4 family, walks the
/// ISO BMFF box tree to read `moov/trak/mdia/minf/stbl/stsd` codec fourccs.
///
/// Never throws on malformed input — every parse failure degrades to `.unknown`
/// (codec) or `nil` (container) rather than propagating, since a still-downloading
/// or corrupt file over SMB is an expected input, not a bug.
public enum MediaProbe {
    /// Byte budget for pulling `moov` into memory. A remux-worthy movie's moov is
    /// single-digit MiB; past this cap codecs degrade to `.unknown` (→ VLC) instead
    /// of an unbounded LAN read.
    private static let moovByteCap = 64 * 1024 * 1024

    /// Mirrors `PlaybackCapabilityMatrix.avKitAudioCodecs` (ParallaxPlayback).
    /// Duplicated rather than imported: ParallaxCore has no dependency on
    /// ParallaxPlayback (and must not gain one). Keep the two sets in sync —
    /// these are the audio codecs AVPlayer's pipeline handles natively.
    private static let avKitAudioCodecs: Set<AudioCodec> = [.aac, .ac3, .eac3, .mp3]

    public static func probe(_ reader: any RandomAccessReading) async throws -> MediaProbeResult {
        let size = try await reader.fileSize
        let head = try await reader.read(offset: 0, length: 12)

        if head.count >= 8, fourCharString(head, at: 4) == "ftyp" {
            let majorBrand = head.count >= 12 ? fourCharString(head, at: 8) : ""
            let container: Container = majorBrand == "qt  " ? .mov : .mp4
            return try await probeMP4(reader: reader, fileSize: size, container: container)
        }

        if head.count >= 4,
           head[head.startIndex] == 0x1A, head[head.startIndex + 1] == 0x45,
           head[head.startIndex + 2] == 0xDF, head[head.startIndex + 3] == 0xA3 {
            return MediaProbeResult(container: .mkv, videoCodec: .none, audioCodec: .none, isComplete: true)
        }

        if head.count >= 12, fourCharString(head, at: 0) == "RIFF", fourCharString(head, at: 8) == "AVI " {
            return MediaProbeResult(container: .avi, videoCodec: .none, audioCodec: .none, isComplete: true)
        }

        if size >= 377 {
            let ts = try await reader.read(offset: 0, length: 377)
            if ts.count == 377,
               ts[ts.startIndex] == 0x47, ts[ts.startIndex + 188] == 0x47, ts[ts.startIndex + 376] == 0x47 {
                return MediaProbeResult(container: .ts, videoCodec: .none, audioCodec: .none, isComplete: true)
            }
        }

        return MediaProbeResult(container: nil, videoCodec: .none, audioCodec: .none, isComplete: true)
    }

    // MARK: - MP4 top-level box walk

    private static func probeMP4(
        reader: any RandomAccessReading,
        fileSize: UInt64,
        container: Container
    ) async throws -> MediaProbeResult {
        let (moovRange, incomplete) = try await walkTopLevel(reader: reader, fileSize: fileSize)

        guard let moovRange else {
            return MediaProbeResult(container: container, videoCodec: .none, audioCodec: .none, isComplete: false)
        }

        guard moovRange.size <= UInt64(moovByteCap) else {
            return MediaProbeResult(container: container, videoCodec: .unknown, audioCodec: .unknown, isComplete: !incomplete)
        }

        let moovData = try await reader.read(offset: moovRange.offset, length: Int(moovRange.size))
        let (video, audio) = parseMoov(moovData)
        return MediaProbeResult(container: container, videoCodec: video, audioCodec: audio, isComplete: !incomplete)
    }

    /// Walks top-level boxes from offset 0. Records the first `moov` box's range
    /// (does not stop there — a later box can still overrun EOF and the whole
    /// file must be walked to know that). `incomplete` is true when any box's
    /// declared extent overruns `fileSize`, or the walk reaches EOF without ever
    /// having seen `moov`.
    private static func walkTopLevel(
        reader: any RandomAccessReading,
        fileSize: UInt64
    ) async throws -> (moovRange: (offset: UInt64, size: UInt64)?, incomplete: Bool) {
        var offset: UInt64 = 0
        var moovRange: (offset: UInt64, size: UInt64)?
        var incomplete = false

        while offset < fileSize {
            guard offset + 8 <= fileSize else { incomplete = true; break }
            let header = try await reader.read(offset: offset, length: 8)
            guard header.count == 8 else { incomplete = true; break }

            let size32 = readUInt32BE(header, at: 0)
            let type = fourCharString(header, at: 4)

            var headerLen: UInt64 = 8
            var boxSize: UInt64
            if size32 == 1 {
                guard offset + 16 <= fileSize else { incomplete = true; break }
                let large = try await reader.read(offset: offset + 8, length: 8)
                guard large.count == 8 else { incomplete = true; break }
                boxSize = readUInt64BE(large, at: 0)
                headerLen = 16
            } else if size32 == 0 {
                boxSize = fileSize - offset
            } else {
                boxSize = UInt64(size32)
            }

            guard boxSize >= headerLen else { incomplete = true; break }
            let (extent, overflowed) = offset.addingReportingOverflow(boxSize)
            guard !overflowed, extent <= fileSize else { incomplete = true; break }

            if type == "moov", moovRange == nil {
                moovRange = (offset, boxSize)
            }

            offset = extent
        }

        if moovRange == nil { incomplete = true }
        return (moovRange, incomplete)
    }

    // MARK: - moov content walk (in-memory, already size-capped)

    private enum TrakKind {
        case video
        case audio
    }

    private struct BoxHeader {
        let type: String
        let contentStart: Int
        let boxEnd: Int
    }

    private static func parseMoov(_ moovData: Data) -> (video: ProbedCodec<VideoCodec>, audio: ProbedCodec<AudioCodec>) {
        guard let moovHeader = readBoxHeader(moovData, at: 0, limit: moovData.count) else {
            return (.unknown, .unknown)
        }

        let traks = allChildBoxes(moovData, type: "trak", in: moovHeader.contentStart..<moovHeader.boxEnd)

        var videoCodec: ProbedCodec<VideoCodec> = .none
        var sawVideoTrak = false
        var sawAudioTrak = false
        var audioFourccsInOrder: [String] = []

        for trak in traks {
            let (kind, fourccs) = extractTrakInfo(moovData, contentRange: trak.contentStart..<trak.boxEnd)
            switch kind {
            case .video:
                guard !sawVideoTrak else { continue }
                sawVideoTrak = true
                if let firstFourcc = fourccs.first, let codec = mapVideoFourcc(firstFourcc) {
                    videoCodec = .known(codec)
                } else {
                    videoCodec = .unknown
                }
            case .audio:
                sawAudioTrak = true
                audioFourccsInOrder.append(contentsOf: fourccs)
            case nil:
                continue
            }
        }

        var audioCodec: ProbedCodec<AudioCodec> = .none
        if sawAudioTrak {
            let mappedInOrder = audioFourccsInOrder.compactMap(mapAudioFourcc)
            if let worstCase = mappedInOrder.first(where: { !avKitAudioCodecs.contains($0) }) {
                audioCodec = .known(worstCase)
            } else if let firstKnown = mappedInOrder.first {
                audioCodec = .known(firstKnown)
            } else {
                audioCodec = .unknown
            }
        }

        return (videoCodec, audioCodec)
    }

    /// `trak → mdia { hdlr, minf → stbl → stsd }`. `hdlr`'s handler fourcc
    /// ("vide"/"soun") tags the trak kind; `stsd` entries (after the 8-byte
    /// version/flags + entry-count header) are boxes whose type IS the codec fourcc.
    private static func extractTrakInfo(
        _ data: Data,
        contentRange: Range<Int>
    ) -> (kind: TrakKind?, fourccs: [String]) {
        guard let mdia = firstChildBox(data, type: "mdia", in: contentRange) else { return (nil, []) }
        let mdiaRange = mdia.contentStart..<mdia.boxEnd

        var kind: TrakKind?
        if let hdlr = firstChildBox(data, type: "hdlr", in: mdiaRange) {
            // hdlr payload: version/flags(4) + pre_defined(4) + handler_type(4) + …
            let handlerOffset = hdlr.contentStart + 8
            if handlerOffset + 4 <= hdlr.boxEnd, handlerOffset + 4 <= data.count {
                switch fourCharString(data, at: handlerOffset) {
                case "vide": kind = .video
                case "soun": kind = .audio
                default: kind = nil
                }
            }
        }

        var fourccs: [String] = []
        if let minf = firstChildBox(data, type: "minf", in: mdiaRange),
           let stbl = firstChildBox(data, type: "stbl", in: minf.contentStart..<minf.boxEnd),
           let stsd = firstChildBox(data, type: "stsd", in: stbl.contentStart..<stbl.boxEnd) {
            let entriesStart = stsd.contentStart + 8 // version/flags(4) + entry_count(4)
            var offset = entriesStart
            while offset < stsd.boxEnd {
                guard let entry = readBoxHeader(data, at: offset, limit: stsd.boxEnd) else { break }
                fourccs.append(entry.type)
                offset = entry.boxEnd
            }
        }

        return (kind, fourccs)
    }

    private static func firstChildBox(_ data: Data, type target: String, in range: Range<Int>) -> BoxHeader? {
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard let header = readBoxHeader(data, at: offset, limit: range.upperBound) else { return nil }
            if header.type == target { return header }
            offset = header.boxEnd
        }
        return nil
    }

    private static func allChildBoxes(_ data: Data, type target: String, in range: Range<Int>) -> [BoxHeader] {
        var offset = range.lowerBound
        var results: [BoxHeader] = []
        while offset < range.upperBound {
            guard let header = readBoxHeader(data, at: offset, limit: range.upperBound) else { break }
            if header.type == target { results.append(header) }
            offset = header.boxEnd
        }
        return results
    }

    /// Same header shape as the top-level walk, bounded by a `limit` (a parent
    /// box's content end) instead of the whole file. Returns `nil` on any
    /// malformed/overrunning header — callers stop walking that branch rather
    /// than crash or misread.
    private static func readBoxHeader(_ data: Data, at offset: Int, limit: Int) -> BoxHeader? {
        guard offset >= 0, offset + 8 <= limit, offset + 8 <= data.count else { return nil }
        let size32 = readUInt32BE(data, at: offset)
        let type = fourCharString(data, at: offset + 4)

        var headerLen = 8
        var boxSize: Int
        if size32 == 1 {
            guard offset + 16 <= limit, offset + 16 <= data.count else { return nil }
            let large = readUInt64BE(data, at: offset + 8)
            guard large <= UInt64(Int.max) else { return nil }
            boxSize = Int(large)
            headerLen = 16
        } else if size32 == 0 {
            boxSize = limit - offset
        } else {
            boxSize = Int(size32)
        }

        guard boxSize >= headerLen else { return nil }
        let boxEnd = offset + boxSize
        guard boxEnd <= limit, boxEnd <= data.count else { return nil }
        return BoxHeader(type: type, contentStart: offset + headerLen, boxEnd: boxEnd)
    }

    // MARK: - fourcc → codec mapping

    private static func mapVideoFourcc(_ fourcc: String) -> VideoCodec? {
        switch fourcc {
        case "avc1", "avc3": return .h264
        case "hvc1", "hev1", "dvh1", "dvhe": return .hevc
        case "av01": return .av1
        case "vp09": return .vp9
        default: return nil
        }
    }

    private static func mapAudioFourcc(_ fourcc: String) -> AudioCodec? {
        switch fourcc {
        case "mp4a": return .aac
        case "ac-3": return .ac3
        case "ec-3": return .eac3
        case "fLaC": return .flac
        case "Opus": return .opus
        case "dtsc", "dtsh", "dtsl", "dtse": return .dts
        case "mlpa": return .trueHD
        default: return nil
        }
    }

    // MARK: - byte helpers (no `load(as:)` — Data buffers aren't guaranteed aligned)

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var result: UInt64 = 0
        for i in 0..<8 { result = (result << 8) | UInt64(data[base + i]) }
        return result
    }

    /// Decodes 4 bytes at `offset` as ASCII/UTF-8 for a fourcc or magic string.
    /// Never throws — invalid byte sequences (garbage/binary) become the Unicode
    /// replacement character rather than crashing, so an unrecognized fourcc
    /// simply fails the `switch` mapping below instead of trapping.
    private static func fourCharString(_ data: Data, at offset: Int) -> String {
        let base = data.startIndex + offset
        return String(decoding: data[base..<(base + 4)], as: UTF8.self)
    }
}

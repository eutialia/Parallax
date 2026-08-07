import Foundation
import ParallaxCore

/// Byte-level EBML / Matroska fixture builders for the cover-art extractor suite.
///
/// `MatroskaCoverArt` reads real MKV/WebM files over SMB, so its tests feed it real EBML trees —
/// hand-assembled here rather than as binary fixtures, so a case reads as "an MKV with a SeekHead
/// pointing past a Cluster at Attachments" instead of an opaque blob.
public enum EBMLFixtures {
    // Well-known element IDs (marker bits included) — same values the walker matches.
    public static let ebmlID: UInt64 = 0x1A45_DFA3
    public static let segmentID: UInt64 = 0x1853_8067
    public static let seekHeadID: UInt64 = 0x114D_9B74
    public static let seekID: UInt64 = 0x4DBB
    public static let seekIDID: UInt64 = 0x53AB
    public static let seekPositionID: UInt64 = 0x53AC
    public static let clusterID: UInt64 = 0x1F43_B675
    public static let attachmentsID: UInt64 = 0x1941_A469
    public static let attachedFileID: UInt64 = 0x61A7
    public static let fileNameID: UInt64 = 0x466E
    public static let fileMimeTypeID: UInt64 = 0x4660
    public static let fileDataID: UInt64 = 0x465C
    /// Opaque Tracks-stub id — something Strategy B must skip without descending.
    public static let tracksID: UInt64 = 0x1654_AE6B

    // MARK: - VINT encoders

    /// Emits the raw ID bytes for a value that already includes its length-marker bits.
    /// `length` is the intended byte width (1…8); the high bytes of `id` must fit.
    public static func idBytes(_ id: UInt64, length: Int) -> Data {
        precondition((1...8).contains(length), "EBML ID length must be 1…8")
        var bytes = Data(count: length)
        for i in 0..<length {
            let shift = (length - 1 - i) * 8
            bytes[i] = UInt8((id >> shift) & 0xFF)
        }
        return bytes
    }

    /// Encodes a known size with the correct marker bit + leading-zero bits for `length` bytes.
    public static func sizeVINT(_ size: UInt64, length: Int) -> Data {
        precondition((1...8).contains(length), "EBML size VINT length must be 1…8")
        let valueBits = length * 7
        let maxValue = valueBits >= 64 ? UInt64.max - 1 : (UInt64(1) << valueBits) &- 2
        // All-ones is reserved for the unknown-size sentinel — known sizes must stay below it.
        precondition(size <= maxValue, "size \(size) does not fit a \(length)-byte size VINT")
        return encodeSizeBits(size, length: length)
    }

    /// The reserved "unknown size" sentinel (every value bit set) for a given VINT width.
    public static func unknownSizeVINT(length: Int) -> Data {
        precondition((1...8).contains(length), "EBML size VINT length must be 1…8")
        let valueBits = length * 7
        let allOnes = valueBits >= 64 ? UInt64.max : (UInt64(1) << valueBits) &- 1
        return encodeSizeBits(allOnes, length: length)
    }

    private static func encodeSizeBits(_ value: UInt64, length: Int) -> Data {
        var bytes = Data(count: length)
        // Marker bit lives at bit index (8 - length) of the first byte.
        let marker: UInt8 = UInt8(1) << (8 - length)
        for i in 0..<length {
            let shift = (length - 1 - i) * 8
            bytes[i] = UInt8((value >> shift) & 0xFF)
        }
        // Overlay the marker on the first byte (value bits already occupy only the low slots).
        bytes[0] = (bytes[0] & (marker &- 1)) | marker
        return bytes
    }

    // MARK: - Element builders

    /// `id bytes + size-VINT + payload`. Size width defaults to the smallest that fits, or
    /// `sizeLength` when forced (useful for unknown-size Segment fixtures).
    public static func element(
        id: UInt64,
        idLength: Int,
        payload: Data,
        sizeLength: Int? = nil,
        unknownSize: Bool = false
    ) -> Data {
        let idData = idBytes(id, length: idLength)
        let sizeData: Data
        if unknownSize {
            let width = sizeLength ?? 8
            sizeData = unknownSizeVINT(length: width)
        } else {
            let width = sizeLength ?? minimalSizeWidth(for: UInt64(payload.count))
            sizeData = sizeVINT(UInt64(payload.count), length: width)
        }
        var data = Data()
        data.append(idData)
        data.append(sizeData)
        data.append(payload)
        return data
    }

    /// Smallest size-VINT width that can hold `size` without colliding with the unknown sentinel.
    public static func minimalSizeWidth(for size: UInt64) -> Int {
        for length in 1...8 {
            let valueBits = length * 7
            let maxKnown = valueBits >= 64 ? UInt64.max - 1 : (UInt64(1) << valueBits) &- 2
            if size <= maxKnown { return length }
        }
        return 8
    }

    // MARK: - Matroska-shaped helpers

    public static func attachedFile(name: String, mimeType: String, fileData: Data) -> Data {
        let namePayload = Data(name.utf8)
        let mimePayload = Data(mimeType.utf8)
        var payload = Data()
        payload.append(element(id: fileNameID, idLength: 2, payload: namePayload))
        payload.append(element(id: fileMimeTypeID, idLength: 2, payload: mimePayload))
        payload.append(element(id: fileDataID, idLength: 2, payload: fileData))
        return element(id: attachedFileID, idLength: 2, payload: payload)
    }

    public static func attachments(
        _ files: [(name: String, mimeType: String, fileData: Data)]
    ) -> Data {
        var payload = Data()
        for file in files {
            payload.append(attachedFile(name: file.name, mimeType: file.mimeType, fileData: file.fileData))
        }
        return element(id: attachmentsID, idLength: 4, payload: payload)
    }

    /// One Seek entry: SeekID (raw element-ID bytes) + SeekPosition (unsigned BE, not a VINT).
    /// Default `positionWidth` is 4 so rebuilding a SeekHead with corrected offsets never
    /// changes its own byte length (a variable-width encode would shift later siblings and
    /// invalidate the offsets just written). Pass 8 only for hostile / wide-position cases.
    public static func seek(
        targetID: UInt64,
        targetIDLength: Int,
        position: UInt64,
        positionWidth: Int = 4
    ) -> Data {
        let idPayload = idBytes(targetID, length: targetIDLength)
        let posPayload = unsignedBE(position, width: positionWidth)
        var payload = Data()
        payload.append(element(id: seekIDID, idLength: 2, payload: idPayload))
        payload.append(element(id: seekPositionID, idLength: 2, payload: posPayload))
        return element(id: seekID, idLength: 2, payload: payload)
    }

    public static func seekHead(_ seeks: [Data]) -> Data {
        element(id: seekHeadID, idLength: 4, payload: seeks.reduce(into: Data()) { $0.append($1) })
    }

    /// Opaque Tracks stub — Strategy B must skip by declared size without looking inside.
    public static func tracksStub(payloadBytes: Int = 8) -> Data {
        element(id: tracksID, idLength: 4, payload: Data(count: payloadBytes))
    }

    /// Opaque Cluster stub — the walk must never enter one under Strategy B.
    public static func clusterStub(payloadBytes: Int = 32) -> Data {
        element(id: clusterID, idLength: 4, payload: Data(count: payloadBytes))
    }

    /// Minimal EBML header element (empty payload is enough — the walker only needs its size).
    public static func ebmlHeader(payload: Data = Data([0x42, 0x86, 0x81, 0x01])) -> Data {
        element(id: ebmlID, idLength: 4, payload: payload)
    }

    // MARK: - Full-file assembly

    /// A segment-level piece whose on-disk offset (relative to Segment data start) is resolved
    /// during assembly so SeekHead entries can point at later siblings without hand-computed
    /// positions.
    public enum SegmentPiece: Sendable {
        /// Seek entries that reference other pieces by index in the same `pieces` array.
        case seekHead(targets: [SeekTarget])
        case tracksStub
        case cluster(payloadBytes: Int)
        case attachments(files: [AttachmentFile])
        /// Pre-built bytes inserted as-is (for corruption / odd-layout cases).
        case raw(Data)
    }

    public struct SeekTarget: Sendable {
        public let pieceIndex: Int
        public let id: UInt64
        public let idLength: Int
        public init(pieceIndex: Int, id: UInt64, idLength: Int) {
            self.pieceIndex = pieceIndex
            self.id = id
            self.idLength = idLength
        }
    }

    public struct AttachmentFile: Sendable {
        public let name: String
        public let mimeType: String
        public let fileData: Data
        public init(name: String, mimeType: String, fileData: Data) {
            self.name = name
            self.mimeType = mimeType
            self.fileData = fileData
        }
    }

    /// Assembles `EBML + Segment { pieces… }`. Seek positions are relative to the Segment's
    /// data start (right after Segment's own ID+size header), matching the Matroska rule.
    public static func mkv(
        unknownSizeSegment: Bool = false,
        pieces: [SegmentPiece]
    ) -> Data {
        // First pass: materialize every non-SeekHead piece so offsets are known.
        // SeekHeads are rebuilt in a second pass once sibling offsets exist.
        var materialized: [Data?] = Array(repeating: nil, count: pieces.count)
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .seekHead:
                materialized[index] = nil // filled below
            case .tracksStub:
                materialized[index] = tracksStub()
            case .cluster(let n):
                materialized[index] = clusterStub(payloadBytes: n)
            case .attachments(let files):
                materialized[index] = attachments(files.map { ($0.name, $0.mimeType, $0.fileData) })
            case .raw(let data):
                materialized[index] = data
            }
        }

        // Placeholder SeekHeads so cumulative offsets of later pieces land correctly.
        // SeekHead size depends on its Seek entries; use a temporary with provisional positions
        // of the same byte-width, then rebuild with true offsets (width is stable for small files).
        func buildSeekHead(targets: [SeekTarget], offsets: [UInt64]) -> Data {
            let seeks = targets.map { target in
                seek(targetID: target.id, targetIDLength: target.idLength, position: offsets[target.pieceIndex])
            }
            return seekHead(seeks)
        }

        // Seed offsets assuming empty SeekHeads, then iterate once more with real ones.
        var offsets = cumulativeOffsets(materialized)
        for (index, piece) in pieces.enumerated() {
            if case .seekHead(let targets) = piece {
                materialized[index] = buildSeekHead(targets: targets, offsets: offsets)
            }
        }
        offsets = cumulativeOffsets(materialized)
        for (index, piece) in pieces.enumerated() {
            if case .seekHead(let targets) = piece {
                materialized[index] = buildSeekHead(targets: targets, offsets: offsets)
            }
        }
        // Offsets must be stable after the second fill (SeekHead byte length shouldn't change
        // when only SeekPosition values change within the same BE width). Recompute once more
        // for safety if a width bump shifted later pieces.
        let finalOffsets = cumulativeOffsets(materialized)
        if finalOffsets != offsets {
            for (index, piece) in pieces.enumerated() {
                if case .seekHead(let targets) = piece {
                    materialized[index] = buildSeekHead(targets: targets, offsets: finalOffsets)
                }
            }
        }

        var segmentPayload = Data()
        for part in materialized {
            segmentPayload.append(part ?? Data())
        }

        let header = ebmlHeader()
        let segment = element(
            id: segmentID, idLength: 4, payload: segmentPayload,
            sizeLength: unknownSizeSegment ? 8 : nil,
            unknownSize: unknownSizeSegment
        )
        return header + segment
    }

    /// Running offset of each piece from the start of the Segment payload.
    private static func cumulativeOffsets(_ parts: [Data?]) -> [UInt64] {
        var offsets: [UInt64] = []
        var running: UInt64 = 0
        for part in parts {
            offsets.append(running)
            running += UInt64((part ?? Data()).count)
        }
        return offsets
    }

    private static func unsignedBE(_ value: UInt64, width: Int) -> Data {
        precondition((1...8).contains(width))
        var data = Data(count: width)
        for i in 0..<width {
            let shift = (width - 1 - i) * 8
            data[i] = UInt8((value >> shift) & 0xFF)
        }
        return data
    }
}

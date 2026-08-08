import Foundation

/// Pulls embedded cover-art image bytes from a Matroska/WebM (EBML) file via
/// random-access reads — the Attachments element, reached through SeekHead when
/// present or a pre-cluster linear scan as fallback.
///
/// Never throws on malformed/absent structure — every parse failure degrades to
/// `nil`, matching `MediaProbe`. Only real I/O failures from the reader propagate,
/// so the caller can classify them as transport faults.
public enum MatroskaCoverArt {
    /// Shared across every metadata read the walk performs (headers, SeekHead,
    /// Attachments child headers/name/mime — NOT the chosen FileData payload).
    /// Sized to `maxStructuralReads` full scan-chunk refills: each attachment whose
    /// payload exceeds a chunk forces its own refill charged at the full chunk size,
    /// so a tighter byte ceiling silently misses a cover appended after ~16 large
    /// fonts — the read-count cap is the real round-trip bound.
    private static let structuralBudget = 1024 * 1024
    /// Hard cap on how many `reader.read` calls the structural walk may issue.
    /// Bounds RTT cost independently of the byte budget (a hostile layout of many
    /// tiny elements could otherwise burn the whole cover-art time budget on
    /// round-trips while staying under the byte ceiling).
    private static let maxStructuralReads = 64
    /// Cap on the FINAL chosen attachment's FileData size. Separate from the
    /// structural budget so a legitimate large cover is still readable in full.
    static let maxAttachmentBytes: UInt64 = 8 * 1024 * 1024

    /// Overflow-checked offset advance. Element sizes are VINT-bounded (≤ 2^56), but offsets
    /// descend from the server-reported file size, which a hostile server can place near
    /// `UInt64.max` — a crafted jump must degrade to absence, never trap.
    private static func advance(_ base: UInt64, by size: UInt64) -> UInt64? {
        let (sum, overflow) = base.addingReportingOverflow(size)
        return overflow ? nil : sum
    }
    /// Bound children walked in any single master element so a garbage size table
    /// can't spin forever.
    private static let maxChildrenPerMaster = 4096
    /// Read-ahead window for dense metadata (SeekHead bulk threshold + Attachments
    /// buffered scan). 16 KiB is large enough that a typical Attachments list's
    /// name/mime headers fit in one or two refills, but small enough that a miss
    /// still charges only a modest slice of the structural byte budget. FileData
    /// payloads are never pulled into this window.
    private static let scanChunk = 16 * 1024
    /// Max bytes for a single FileName / FileMimeType payload we'll materialize.
    private static let maxStringPayload = 1024

    // Element IDs keep their length-marker bits (raw N-byte values).
    private static let idEBML: UInt64 = 0x1A45_DFA3
    private static let idSegment: UInt64 = 0x1853_8067
    private static let idSeekHead: UInt64 = 0x114D_9B74
    private static let idSeek: UInt64 = 0x4DBB
    private static let idSeekID: UInt64 = 0x53AB
    private static let idSeekPosition: UInt64 = 0x53AC
    private static let idCluster: UInt64 = 0x1F43_B675
    private static let idAttachments: UInt64 = 0x1941_A469
    private static let idAttachedFile: UInt64 = 0x61A7
    private static let idFileName: UInt64 = 0x466E
    private static let idFileMimeType: UInt64 = 0x4660
    private static let idFileData: UInt64 = 0x465C

    // MARK: - Public entry

    public static func extract(_ reader: any RandomAccessReading) async throws -> Data? {
        let fileSize = try await reader.fileSize
        guard fileSize >= 4 else { return nil }

        let magic = try await reader.read(offset: 0, length: 4)
        guard magic.count == 4,
              magic[magic.startIndex] == 0x1A,
              magic[magic.startIndex + 1] == 0x45,
              magic[magic.startIndex + 2] == 0xDF,
              magic[magic.startIndex + 3] == 0xA3
        else { return nil }

        let state = WalkState(
            reader: reader,
            fileSize: fileSize,
            budget: structuralBudget,
            maxReads: maxStructuralReads
        )

        // EBML header — only need its extent so the next top-level element starts right after.
        guard let ebml = try await state.readHeader(at: 0),
              ebml.id == idEBML,
              case .known(let ebmlSize) = ebml.size,
              let afterEBML = advance(ebml.dataStart, by: ebmlSize)
        else { return nil }

        guard let segment = try await state.readHeader(at: afterEBML),
              segment.id == idSegment
        else { return nil }

        let segmentDataStart = segment.dataStart
        let segmentDataEnd: UInt64?
        switch segment.size {
        case .known(let size):
            guard let end = advance(segmentDataStart, by: size) else { return nil }
            segmentDataEnd = end
        case .unknown:
            // Legal only for Segment here — treat as "extends to EOF".
            segmentDataEnd = fileSize
        }

        // Strategy A: SeekHead → Attachments (one optional second-SeekHead hop).
        var attachmentsRange: (offset: UInt64, size: UInt64)?
        /// When the SeekHead parsed cleanly with no Attachments entry, a linear
        /// re-scan cannot find one either — skip Strategy B entirely.
        var skipStrategyB = false
        if let seekHead = try await findFirstLevel(
            state: state,
            from: segmentDataStart,
            end: segmentDataEnd,
            want: idSeekHead,
            stopAt: idCluster
        ) {
            if case .known(let shSize) = seekHead.size {
                switch try await resolveAttachmentsViaSeekHead(
                    state: state,
                    seekHeadDataStart: seekHead.dataStart,
                    seekHeadSize: shSize,
                    segmentDataStart: segmentDataStart,
                    allowSecondHop: true
                ) {
                case .found(let offset, let size):
                    attachmentsRange = (offset, size)
                case .noAttachmentsEntry:
                    skipStrategyB = true
                case .inconclusive:
                    break
                }
            }
        }

        // Strategy B: linear pre-cluster walk when SeekHead was missing, unusable,
        // or inconclusive — never when a complete SeekHead authoritatively omitted
        // Attachments.
        if attachmentsRange == nil, !skipStrategyB {
            attachmentsRange = try await findAttachmentsBeforeCluster(
                state: state,
                from: segmentDataStart,
                end: segmentDataEnd
            )
        }

        guard let attachmentsRange else { return nil }
        let candidates = try await collectAttachedFiles(
            state: state,
            attachmentsOffset: attachmentsRange.offset,
            attachmentsSize: attachmentsRange.size
        )
        guard let winner = selectCoverArt(from: candidates) else { return nil }

        // FileData payload is outside the structural budget — the attachment cap alone applies.
        let length = Int(winner.fileDataSize)
        guard length > 0, UInt64(length) == winner.fileDataSize else { return nil }
        let data = try await reader.read(offset: winner.fileDataOffset, length: length)
        guard data.count == length else { return nil }
        return data
    }

    // MARK: - Candidate selection (pure, unit-testable via @testable)

    /// One Attachments child the walk collected without materializing FileData bytes.
    struct AttachmentCandidate: Sendable, Equatable {
        let name: String
        let mimeType: String
        let fileDataOffset: UInt64
        let fileDataSize: UInt64
    }

    /// Prefer Matroska's cover-art name tiers, then the first remaining `image/*`
    /// under the attachment-size cap. Non-images and oversize payloads are skipped.
    /// Order: `cover.` → `cover_land.` → `small_cover.` → `small_cover_land.` → first image.
    static func selectCoverArt(from candidates: [AttachmentCandidate]) -> AttachmentCandidate? {
        let images = candidates.filter {
            $0.mimeType.hasPrefix("image/") && $0.fileDataSize <= maxAttachmentBytes && $0.fileDataSize > 0
        }
        if let cover = images.first(where: { $0.name.hasPrefix("cover.") }) { return cover }
        if let land = images.first(where: { $0.name.hasPrefix("cover_land.") }) { return land }
        if let small = images.first(where: { $0.name.hasPrefix("small_cover.") }) { return small }
        if let smallLand = images.first(where: { $0.name.hasPrefix("small_cover_land.") }) { return smallLand }
        return images.first
    }

    /// Top-priority tier only — a later sibling can never outrank `cover.` + image/* + size-ok,
    /// so the buffered Attachments scan may stop the moment one is confirmed.
    private static func isTopPriorityCover(_ file: AttachmentCandidate) -> Bool {
        file.name.hasPrefix("cover.")
            && file.mimeType.hasPrefix("image/")
            && file.fileDataSize > 0
            && file.fileDataSize <= maxAttachmentBytes
    }

    // MARK: - Strategy A / B

    /// Three-way SeekHead outcome so a clean "no Attachments" result is not
    /// confused with a failed/partial parse (which still warrants Strategy B).
    private enum SeekHeadResolution {
        case found(offset: UInt64, size: UInt64)
        /// The SeekHead (and its second-hop, if followed) parsed to completion with
        /// no Attachments Seek entry among them — authoritative: Strategy B must not run.
        case noAttachmentsEntry
        /// A read, a hop, or a nested parse failed, was corrupt, or hit a budget wall —
        /// genuinely unknown; Strategy B may still find it.
        case inconclusive
    }

    /// Walk first-level Segment children for `want`, stopping without consuming a Cluster.
    private static func findFirstLevel(
        state: WalkState,
        from start: UInt64,
        end: UInt64?,
        want: UInt64,
        stopAt: UInt64
    ) async throws -> ElementHeader? {
        var offset = start
        var children = 0
        while children < maxChildrenPerMaster {
            if let end, offset >= end { return nil }
            guard let header = try await state.readHeader(at: offset) else { return nil }
            if header.id == stopAt { return nil }
            if header.id == want { return header }
            // Unknown-size non-Segment: unrecoverable here.
            guard case .known(let size) = header.size else { return nil }
            guard let next = advance(header.dataStart, by: size),
                  next > offset else { return nil } // must advance — also catches size == 0
            offset = next
            children += 1
        }
        return nil
    }

    /// Parse a SeekHead for an Attachments Seek entry; optionally follow one hop to a second SeekHead.
    private static func resolveAttachmentsViaSeekHead(
        state: WalkState,
        seekHeadDataStart: UInt64,
        seekHeadSize: UInt64,
        segmentDataStart: UInt64,
        allowSecondHop: Bool
    ) async throws -> SeekHeadResolution {
        let parsed = try await parseSeekEntries(
            state: state,
            dataStart: seekHeadDataStart,
            dataSize: seekHeadSize
        )

        var secondSeekHeadPos: UInt64?
        for seek in parsed.entries {
            if seek.id == idAttachments {
                // SATURATING / rejecting, not wrapping: SeekPosition is attacker-controlled
                // (up to 8 bytes). Plain `+` traps on overflow in Swift; a bogus jump target
                // has nothing useful to clamp TO, so overflow or out-of-range is corruption → nil branch.
                let (abs, overflowed) = segmentDataStart.addingReportingOverflow(seek.position)
                guard !overflowed, abs < state.fileSize else { return .inconclusive }
                guard let header = try await state.readHeader(at: abs),
                      header.id == idAttachments,
                      case .known(let size) = header.size
                else { return .inconclusive }
                // Return the element's data range (children live in the payload).
                return .found(offset: header.dataStart, size: size)
            }
            if allowSecondHop, seek.id == idSeekHead, secondSeekHeadPos == nil {
                secondSeekHeadPos = seek.position
            }
        }

        if allowSecondHop, let hop = secondSeekHeadPos {
            let (abs, overflowed) = segmentDataStart.addingReportingOverflow(hop)
            guard !overflowed, abs < state.fileSize else { return .inconclusive }
            guard let header = try await state.readHeader(at: abs),
                  header.id == idSeekHead,
                  case .known(let size) = header.size
            else { return .inconclusive }
            // Exactly one extra hop — don't recurse further.
            let nested = try await resolveAttachmentsViaSeekHead(
                state: state,
                seekHeadDataStart: header.dataStart,
                seekHeadSize: size,
                segmentDataStart: segmentDataStart,
                allowSecondHop: false
            )
            switch nested {
            case .found:
                return nested
            case .noAttachmentsEntry:
                // Nested was clean, but only the full chain is authoritative.
                return parsed.completed ? .noAttachmentsEntry : .inconclusive
            case .inconclusive:
                return .inconclusive
            }
        }

        return parsed.completed ? .noAttachmentsEntry : .inconclusive
    }

    private struct SeekEntry {
        let id: UInt64
        let position: UInt64
    }

    private struct SeekParseResult {
        let entries: [SeekEntry]
        /// True only when the entire `dataSize` range was walked without a parse
        /// failure or early bail — required to treat "no Attachments entry" as
        /// authoritative rather than "we gave up before finding one."
        let completed: Bool
    }

    private static func parseSeekEntries(
        state: WalkState,
        dataStart: UInt64,
        dataSize: UInt64
    ) async throws -> SeekParseResult {
        let (end, endOverflow) = dataStart.addingReportingOverflow(dataSize)
        guard !endOverflow else { return SeekParseResult(entries: [], completed: false) }

        // Prefer one bulk pull when the SeekHead is modest — fewer SMB round trips.
        if dataSize <= UInt64(scanChunk),
           let blob = try await state.readStructural(offset: dataStart, length: Int(dataSize)),
           blob.count == Int(dataSize) {
            return parseSeekEntriesInMemory(blob)
        }

        var entries: [SeekEntry] = []
        var offset = dataStart
        var children = 0
        while offset < end, children < maxChildrenPerMaster {
            guard let header = try await state.readHeader(at: offset),
                  case .known(let size) = header.size
            else { return SeekParseResult(entries: entries, completed: false) }
            let (next, nextOverflow) = header.dataStart.addingReportingOverflow(size)
            guard !nextOverflow, next > offset, next <= end else {
                return SeekParseResult(entries: entries, completed: false)
            }
            if header.id == idSeek {
                if let entry = try await parseSeek(
                    state: state, dataStart: header.dataStart, dataSize: size
                ) {
                    entries.append(entry)
                }
            }
            offset = next
            children += 1
        }
        let completed = offset >= end
        return SeekParseResult(entries: entries, completed: completed)
    }

    private static func parseSeekEntriesInMemory(_ data: Data) -> SeekParseResult {
        var entries: [SeekEntry] = []
        var offset = 0
        var children = 0
        while offset < data.count, children < maxChildrenPerMaster {
            guard let header = parseHeaderInMemory(data, at: offset) else {
                return SeekParseResult(entries: entries, completed: false)
            }
            guard case .known(let size) = header.size else {
                return SeekParseResult(entries: entries, completed: false)
            }
            let next = header.contentStart + Int(size)
            guard next > offset, next <= data.count else {
                return SeekParseResult(entries: entries, completed: false)
            }
            if header.id == idSeek {
                if let entry = parseSeekInMemory(
                    data, contentStart: header.contentStart, contentEnd: next
                ) {
                    entries.append(entry)
                }
            }
            offset = next
            children += 1
        }
        return SeekParseResult(entries: entries, completed: offset >= data.count)
    }

    private static func parseSeek(
        state: WalkState, dataStart: UInt64, dataSize: UInt64
    ) async throws -> SeekEntry? {
        guard let blob = try await state.readStructural(offset: dataStart, length: Int(dataSize)),
              blob.count == Int(dataSize)
        else { return nil }
        return parseSeekInMemory(blob, contentStart: 0, contentEnd: blob.count)
    }

    private static func parseSeekInMemory(
        _ data: Data, contentStart: Int, contentEnd: Int
    ) -> SeekEntry? {
        var seekID: UInt64?
        var seekPos: UInt64?
        var offset = contentStart
        var children = 0
        while offset < contentEnd, children < maxChildrenPerMaster {
            guard let header = parseHeaderInMemory(data, at: offset) else { break }
            guard case .known(let size) = header.size else { break }
            let payloadStart = header.contentStart
            let payloadEnd = payloadStart + Int(size)
            guard payloadEnd > offset, payloadEnd <= contentEnd, payloadEnd <= data.count else { break }
            if header.id == idSeekID, size > 0, size <= 8 {
                seekID = readRawID(data, at: payloadStart, length: Int(size))
            } else if header.id == idSeekPosition, size > 0, size <= 8 {
                seekPos = readUnsignedBE(data, at: payloadStart, length: Int(size))
            }
            offset = payloadEnd
            children += 1
        }
        guard let id = seekID, let pos = seekPos else { return nil }
        return SeekEntry(id: id, position: pos)
    }

    /// Strategy B: walk Segment top-level children; stop at first Cluster without descending.
    private static func findAttachmentsBeforeCluster(
        state: WalkState,
        from start: UInt64,
        end: UInt64?
    ) async throws -> (offset: UInt64, size: UInt64)? {
        var offset = start
        var children = 0
        while children < maxChildrenPerMaster {
            if let end, offset >= end { return nil }
            guard let header = try await state.readHeader(at: offset) else { return nil }
            if header.id == idCluster { return nil }
            if header.id == idAttachments, case .known(let size) = header.size {
                return (header.dataStart, size)
            }
            guard case .known(let size) = header.size else { return nil }
            guard let next = advance(header.dataStart, by: size),
                  next > offset else { return nil }
            offset = next
            children += 1
        }
        return nil
    }

    // MARK: - Attachments collection (buffered scan)

    /// Walk Attachments children via a read-ahead window. FileName/FileMimeType are
    /// parsed from the buffer; FileData is recorded by offset and skipped without
    /// reading payload bytes. Stops early once a top-priority `cover.` candidate is
    /// confirmed — nothing later can outrank it.
    private static func collectAttachedFiles(
        state: WalkState,
        attachmentsOffset: UInt64,
        attachmentsSize: UInt64
    ) async throws -> [AttachmentCandidate] {
        let (end, endOverflow) = attachmentsOffset.addingReportingOverflow(attachmentsSize)
        guard !endOverflow else { return [] }

        var window = ScanWindow(
            state: state,
            rangeEnd: end,
            cursor: attachmentsOffset
        )
        var candidates: [AttachmentCandidate] = []
        var children = 0
        while window.cursor < end, children < maxChildrenPerMaster {
            guard let header = try await window.parseKnownHeader() else { break }
            let (next, nextOverflow) = header.dataStart.addingReportingOverflow(header.size)
            guard !nextOverflow, next > window.cursor, next <= end else { break }

            if header.id == idAttachedFile {
                if let file = try await parseAttachedFileBuffered(
                    window: &window,
                    dataStart: header.dataStart,
                    dataEnd: next
                ) {
                    candidates.append(file)
                    if isTopPriorityCover(file) {
                        return candidates
                    }
                }
            }
            window.cursor = next
            children += 1
        }
        return candidates
    }

    private static func parseAttachedFileBuffered(
        window: inout ScanWindow,
        dataStart: UInt64,
        dataEnd: UInt64
    ) async throws -> AttachmentCandidate? {
        window.cursor = dataStart
        var name: String?
        var mime: String?
        var fileDataOffset: UInt64?
        var fileDataSize: UInt64?
        var children = 0
        while window.cursor < dataEnd, children < maxChildrenPerMaster {
            guard let header = try await window.parseKnownHeader() else { break }
            let (next, nextOverflow) = header.dataStart.addingReportingOverflow(header.size)
            guard !nextOverflow, next > window.cursor, next <= dataEnd else { break }

            switch header.id {
            case idFileName:
                if header.size > 0, header.size <= UInt64(maxStringPayload),
                   let bytes = try await window.bytes(at: header.dataStart, count: Int(header.size)) {
                    name = String(decoding: bytes, as: UTF8.self)
                }
            case idFileMimeType:
                if header.size > 0, header.size <= UInt64(maxStringPayload),
                   let bytes = try await window.bytes(at: header.dataStart, count: Int(header.size)) {
                    mime = String(decoding: bytes, as: UTF8.self)
                }
            case idFileData:
                // Record only — never pull FileData into the buffer. Advancing
                // `cursor` past this element makes the next refill start after it.
                fileDataOffset = header.dataStart
                fileDataSize = header.size
            default:
                break
            }
            window.cursor = next
            children += 1
        }
        guard let name, let mime, let fileDataOffset, let fileDataSize else { return nil }
        return AttachmentCandidate(
            name: name, mimeType: mime,
            fileDataOffset: fileDataOffset, fileDataSize: fileDataSize
        )
    }

    // MARK: - Header / VINT parsing

    private enum ElementSize: Equatable {
        case known(UInt64)
        case unknown
    }

    private struct ElementHeader {
        let id: UInt64
        let size: ElementSize
        let headerLength: Int
        let dataStart: UInt64
    }

    /// In-memory header parse used when a master element's payload was bulk-read
    /// or when the Attachments scan window already covers the bytes.
    private struct MemHeader {
        let id: UInt64
        let size: ElementSize
        let contentStart: Int
    }

    /// Known-size element located at an absolute file offset (from a ScanWindow).
    private struct BufferedHeader {
        let id: UInt64
        let size: UInt64
        let dataStart: UInt64
    }

    private static func parseHeaderInMemory(_ data: Data, at offset: Int) -> MemHeader? {
        guard offset < data.count else { return nil }
        guard let (id, idLen) = decodeID(data, at: offset) else { return nil }
        let sizeAt = offset + idLen
        guard sizeAt < data.count else { return nil }
        guard let (size, sizeLen) = decodeSize(data, at: sizeAt) else { return nil }
        let contentStart = sizeAt + sizeLen
        guard contentStart <= data.count else { return nil }
        return MemHeader(id: id, size: size, contentStart: contentStart)
    }

    /// Element ID: raw N bytes including length-marker bits.
    private static func decodeID(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        guard offset < data.count else { return nil }
        let first = data[data.startIndex + offset]
        guard first != 0 else { return nil } // would need a 9th byte — corrupt
        let length = vintWidth(first)
        guard length >= 1, length <= 8, offset + length <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<length {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return (value, length)
    }

    /// Size VINT: strip marker bit + leading zeros; all-ones value bits ⇒ unknown-size sentinel.
    private static func decodeSize(_ data: Data, at offset: Int) -> (ElementSize, Int)? {
        guard offset < data.count else { return nil }
        let first = data[data.startIndex + offset]
        guard first != 0 else { return nil }
        let length = vintWidth(first)
        guard length >= 1, length <= 8, offset + length <= data.count else { return nil }

        // Marker bit position: bit (8 - length) of the first byte.
        let markerMask: UInt8 = UInt8(1) << (8 - length)
        let firstValue = first & (markerMask &- 1) // low bits under the marker

        var value: UInt64 = UInt64(firstValue)
        for i in 1..<length {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }

        // All value bits set ⇒ unknown size. A length-n VINT carries 7*n value bits: (8-n) in the
        // first byte (after its marker) plus 8 from each of the remaining (n-1) bytes.
        let valueBits = length * 7
        // Guard against shift overflow on theoretical 8-byte (56 value bits fits UInt64).
        let allOnes: UInt64 = valueBits >= 64 ? UInt64.max : (UInt64(1) << valueBits) &- 1
        if value == allOnes {
            return (.unknown, length)
        }
        return (.known(value), length)
    }

    /// Width of a VINT from its first byte's leading-1 position. `0` first byte is invalid.
    private static func vintWidth(_ first: UInt8) -> Int {
        if first & 0x80 != 0 { return 1 }
        if first & 0x40 != 0 { return 2 }
        if first & 0x20 != 0 { return 3 }
        if first & 0x10 != 0 { return 4 }
        if first & 0x08 != 0 { return 5 }
        if first & 0x04 != 0 { return 6 }
        if first & 0x02 != 0 { return 7 }
        if first & 0x01 != 0 { return 8 }
        return 0
    }

    private static func readRawID(_ data: Data, at offset: Int, length: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<length {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    /// Plain unsigned big-endian integer (SeekPosition is NOT a VINT).
    private static func readUnsignedBE(_ data: Data, at offset: Int, length: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<length {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    // MARK: - Buffered scan window

    /// Read-ahead cursor over a fixed file range. Parses element headers and small
    /// string payloads from an in-memory window refilled in `scanChunk` pulls;
    /// large FileData spans are advanced past without ever loading their bytes.
    private struct ScanWindow {
        let state: WalkState
        let rangeEnd: UInt64
        var cursor: UInt64
        private var buffer = Data()
        /// File offset of `buffer.startIndex`.
        private var bufferOrigin: UInt64 = 0

        init(state: WalkState, rangeEnd: UInt64, cursor: UInt64) {
            self.state = state
            self.rangeEnd = rangeEnd
            self.cursor = cursor
        }

        /// Parse a known-size element header at `cursor` from the window (refilling as needed).
        mutating func parseKnownHeader() async throws -> BufferedHeader? {
            guard cursor < rangeEnd else { return nil }
            let remaining = rangeEnd - cursor
            // Need at least a 1-byte ID + 1-byte size; prefer a full 16-byte max header.
            let want = min(16, Int(min(remaining, UInt64(Int.max))))
            guard want >= 2 else { return nil }
            guard try await ensure(need: want) else { return nil }

            let rel = Int(cursor - bufferOrigin)
            guard let mem = MatroskaCoverArt.parseHeaderInMemory(buffer, at: rel) else { return nil }
            guard case .known(let size) = mem.size else { return nil }
            let headerLength = mem.contentStart - rel
            guard headerLength > 0 else { return nil }
            // Cursor can descend from a server-reported size — same near-max trap class as
            // `advance`, so degrade to absence instead of trapping.
            let (dataStart, overflowed) = cursor.addingReportingOverflow(UInt64(headerLength))
            guard !overflowed else { return nil }
            return BufferedHeader(id: mem.id, size: size, dataStart: dataStart)
        }

        /// Materialize `count` bytes at an absolute file offset from the window.
        mutating func bytes(at offset: UInt64, count: Int) async throws -> Data? {
            guard count > 0 else { return Data() }
            let saved = cursor
            cursor = offset
            defer { cursor = saved }
            guard try await ensure(need: count) else { return nil }
            let rel = Int(offset - bufferOrigin)
            guard rel >= 0, rel + count <= buffer.count else { return nil }
            return buffer.subdata(in: rel..<(rel + count))
        }

        /// Ensure the window covers `[cursor, cursor + need)`. Refills from `cursor`
        /// when the existing buffer doesn't already contain that span.
        private mutating func ensure(need: Int) async throws -> Bool {
            guard need > 0 else { return true }
            if cursor >= bufferOrigin {
                let into = cursor - bufferOrigin
                if into <= UInt64(buffer.count) {
                    let available = buffer.count - Int(into)
                    if available >= need { return true }
                }
            }

            guard cursor < rangeEnd else { return false }
            let remaining = rangeEnd - cursor
            let remainingInt = Int(min(remaining, UInt64(Int.max)))
            guard remainingInt >= need else { return false }

            let pull = min(max(need, MatroskaCoverArt.scanChunk), remainingInt)
            guard let data = try await state.readStructural(offset: cursor, length: pull),
                  data.count >= need
            else { return false }
            buffer = data
            bufferOrigin = cursor
            return true
        }
    }

    // MARK: - Structural walk state (budget + modest reads)

    /// Tracks the structural byte/read budgets and issues size-capped reader pulls.
    /// FileData payload reads intentionally bypass this type so they don't share
    /// the `structuralBudget` / `maxStructuralReads` ceilings.
    ///
    /// `@unchecked Sendable`: one instance is created per `extract()` call and
    /// mutated only on that call's single sequential `await` chain — it never
    /// escapes `extract` or is shared across concurrent tasks.
    private final class WalkState: @unchecked Sendable {
        let reader: any RandomAccessReading
        let fileSize: UInt64
        private var budgetRemaining: Int
        private var readsRemaining: Int

        init(reader: any RandomAccessReading, fileSize: UInt64, budget: Int, maxReads: Int) {
            self.reader = reader
            self.fileSize = fileSize
            self.budgetRemaining = budget
            self.readsRemaining = maxReads
        }

        /// Reads up to 16 bytes (max ID+size VINT pair) and parses an element header.
        func readHeader(at offset: UInt64) async throws -> ElementHeader? {
            guard offset < fileSize else { return nil }
            // Max ID (8) + max size (8) = 16.
            guard let head = try await readStructural(offset: offset, length: 16), !head.isEmpty else {
                return nil
            }
            guard let (id, idLen) = MatroskaCoverArt.decodeID(head, at: 0) else { return nil }
            guard idLen < head.count else { return nil }
            guard let (size, sizeLen) = MatroskaCoverArt.decodeSize(head, at: idLen) else { return nil }
            let headerLength = idLen + sizeLen
            // A zero-length header can't advance the walk — treat as corrupt.
            guard headerLength > 0 else { return nil }
            // Offset can descend from a server-reported size — same near-max trap class as
            // `advance`, so degrade to absence instead of trapping.
            let (dataStart, overflowed) = offset.addingReportingOverflow(UInt64(headerLength))
            guard !overflowed else { return nil }
            return ElementHeader(id: id, size: size, headerLength: headerLength, dataStart: dataStart)
        }

        /// Structural read charged against the walk's byte and read-count budgets.
        /// Returns nil when either budget is exhausted or the pull is empty — never
        /// throws for budget; I/O errors still propagate.
        func readStructural(offset: UInt64, length: Int) async throws -> Data? {
            guard length > 0, budgetRemaining > 0, readsRemaining > 0 else { return nil }
            let want = min(length, budgetRemaining)
            readsRemaining -= 1
            let data = try await reader.read(offset: offset, length: want)
            budgetRemaining -= data.count
            return data
        }
    }
}

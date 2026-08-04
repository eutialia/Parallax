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

/// Structural defects that make AVFoundation misplay a file the VLC engine handles.
public enum AVPlayerHazard: Sendable, Hashable {
    /// H.264 with B-frames but no real composition offsets: AVPlayer displays decode order (motion judder).
    case decodeOrderTimestamps
    /// hev1/avc3/avc4/dvhe sample entries carry parameter sets in-band; AVFoundation only accepts them out-of-band (avc1/hvc1/dvh1), so playback is black video with running audio.
    case inBandParameterSets
    /// Field-coded (interlaced) H.264/HEVC: AVFoundation's decode path has no field coding, so playback is black video or visibly combed.
    case interlacedVideo
    /// The video trak's stsd declares more than one sample entry: a mid-stream format change AVKit handles poorly.
    case multipleSampleDescriptions
    /// avcC declares zero SPS entries: a guaranteed decoder failure (-8971).
    case missingParameterSets
}

public struct MediaProbeResult: Sendable, Equatable {
    public let container: Container?
    public let videoCodec: ProbedCodec<VideoCodec>
    public let audioCodec: ProbedCodec<AudioCodec>
    /// False when the MP4 box walk proves the file is truncated / still downloading
    /// (a box's declared extent overruns `fileSize`, or EOF arrives before any
    /// `moov` box). A malformed top-level header (declared size shorter than the
    /// 8/16-byte header itself, or a short read at EOF) is treated the same way —
    /// the conservative read is "not yet fully written" rather than "corrupt."
    /// Non-MP4 containers always report true — VLC owns them as-is, truncation
    /// there isn't this probe's signal to detect.
    public let isComplete: Bool
    /// Structural defects proven by walking the sample tables — empty on every container
    /// but MP4/MOV, and on an MP4/MOV whose first video trak doesn't exhibit one.
    public let avPlayerHazards: Set<AVPlayerHazard>

    public init(
        container: Container?,
        videoCodec: ProbedCodec<VideoCodec>,
        audioCodec: ProbedCodec<AudioCodec>,
        isComplete: Bool,
        avPlayerHazards: Set<AVPlayerHazard> = []
    ) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.isComplete = isComplete
        self.avPlayerHazards = avPlayerHazards
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
        let (video, audio, hazards) = await parseMoov(moovData, reader: reader)
        return MediaProbeResult(
            container: container, videoCodec: video, audioCodec: audio,
            isComplete: !incomplete, avPlayerHazards: hazards
        )
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

    private static func parseMoov(
        _ moovData: Data,
        reader: any RandomAccessReading
    ) async -> (video: ProbedCodec<VideoCodec>, audio: ProbedCodec<AudioCodec>, hazards: Set<AVPlayerHazard>) {
        guard let moovHeader = readBoxHeader(moovData, at: 0, limit: moovData.count) else {
            return (.unknown, .unknown, [])
        }

        let traks = allChildBoxes(moovData, type: "trak", in: moovHeader.contentStart..<moovHeader.boxEnd)

        var videoCodec: ProbedCodec<VideoCodec> = .none
        var sawVideoTrak = false
        var sawAudioTrak = false
        var audioFourccsInOrder: [String] = []
        var hazards: Set<AVPlayerHazard> = []

        for trak in traks {
            let info = extractTrakInfo(moovData, contentRange: trak.contentStart..<trak.boxEnd)
            switch info.kind {
            case .video:
                guard !sawVideoTrak else { continue }
                sawVideoTrak = true
                if let firstFourcc = info.fourccs.first {
                    let mappedCodec = mapVideoFourcc(firstFourcc)
                    videoCodec = mappedCodec.map(ProbedCodec.known) ?? .unknown
                    hazards.formUnion(await detectVideoTrakHazards(
                        data: moovData,
                        firstFourcc: firstFourcc,
                        mappedCodec: mappedCodec,
                        sampleEntryCount: info.fourccs.count,
                        stblRange: info.stblRange,
                        firstStsdEntry: info.firstStsdEntry,
                        reader: reader
                    ))
                } else {
                    videoCodec = .unknown
                }
            case .audio:
                sawAudioTrak = true
                audioFourccsInOrder.append(contentsOf: info.fourccs)
            case nil:
                continue
            }
        }

        var audioCodec: ProbedCodec<AudioCodec> = .none
        if sawAudioTrak {
            let mappedInOrder = audioFourccsInOrder.map(mapAudioFourcc)
            if mappedInOrder.contains(where: { $0 == nil }) {
                // Any unrecognized audio fourcc must surface as `.unknown` per
                // `ProbedCodec`'s contract — silently dropping it and picking a
                // worst-case among the recognized tracks would hide a track
                // `EngineSelector` can't reason about.
                audioCodec = .unknown
            } else if let worstCase = mappedInOrder.compactMap({ $0 }).first(where: { !AudioCodec.avPlayerSupported.contains($0) }) {
                audioCodec = .known(worstCase)
            } else if let firstKnown = mappedInOrder.compactMap({ $0 }).first {
                audioCodec = .known(firstKnown)
            } else {
                audioCodec = .unknown
            }
        }

        return (videoCodec, audioCodec, hazards)
    }

    private struct TrakInfo {
        let kind: TrakKind?
        let fourccs: [String]
        /// `stbl`'s content range, in `moovData` coordinates — where `stts`/`ctts`/`stsz`/
        /// `stsc`/`stco`/`co64` live. Populated only when the trak resolved a full
        /// `mdia → minf → stbl → stsd` path.
        let stblRange: Range<Int>?
        /// The first `stsd` sample entry box (e.g. `avc1`) — where `avcC` lives.
        let firstStsdEntry: BoxHeader?
    }

    /// `trak → mdia { hdlr, minf → stbl → stsd }`. `hdlr`'s handler fourcc
    /// ("vide"/"soun") tags the trak kind; `stsd` entries (after the 8-byte
    /// version/flags + entry-count header) are boxes whose type IS the codec fourcc. The walk
    /// stops at the box's declared `entry_count` rather than `stsd`'s box end — a trailing
    /// `free`/`skip` padding box (or even 8+ zero bytes, which parse as a phantom empty-type
    /// entry) would otherwise read as a second sample description that was never there.
    private static func extractTrakInfo(
        _ data: Data,
        contentRange: Range<Int>
    ) -> TrakInfo {
        guard let mdia = firstChildBox(data, type: "mdia", in: contentRange) else {
            return TrakInfo(kind: nil, fourccs: [], stblRange: nil, firstStsdEntry: nil)
        }
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
        var stblRange: Range<Int>?
        var firstStsdEntry: BoxHeader?
        if let minf = firstChildBox(data, type: "minf", in: mdiaRange),
           let stbl = firstChildBox(data, type: "stbl", in: minf.contentStart..<minf.boxEnd),
           let stsd = firstChildBox(data, type: "stsd", in: stbl.contentStart..<stbl.boxEnd) {
            stblRange = stbl.contentStart..<stbl.boxEnd
            let entryCountOffset = stsd.contentStart + 4
            let declaredEntryCount: Int
            if entryCountOffset + 4 <= stsd.boxEnd, entryCountOffset + 4 <= data.count {
                declaredEntryCount = Int(readUInt32BE(data, at: entryCountOffset))
            } else {
                declaredEntryCount = 0
            }
            let entriesStart = stsd.contentStart + 8 // version/flags(4) + entry_count(4)
            var offset = entriesStart
            while offset < stsd.boxEnd, fourccs.count < declaredEntryCount {
                guard let entry = readBoxHeader(data, at: offset, limit: stsd.boxEnd) else { break }
                fourccs.append(entry.type)
                if firstStsdEntry == nil { firstStsdEntry = entry }
                offset = entry.boxEnd
            }
        }

        return TrakInfo(kind: kind, fourccs: fourccs, stblRange: stblRange, firstStsdEntry: firstStsdEntry)
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
        let (boxEnd, overflowed) = offset.addingReportingOverflow(boxSize)
        guard !overflowed, boxEnd <= limit, boxEnd <= data.count else { return nil }
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

    // MARK: - decode-order timestamp hazard (H.264 B-frames + degenerate ctts)

    private struct SttsEntry {
        let sampleCount: UInt32
        let sampleDelta: UInt32
    }

    private struct CttsRun {
        let count: UInt32
        let offset: Int32
    }

    private struct StscEntry {
        let firstChunk: UInt32
        let samplesPerChunk: UInt32
    }

    private enum CttsOutcome {
        case absent
        case malformed
        case parsed([CttsRun])
    }

    private struct DegeneracyAnalysis {
        let isCandidate: Bool
        /// Decode-order sample index to start the B-slice confirmation read at.
        let firstSampleIndex: Int
    }

    /// Determines whether the FIRST h264 video trak exhibits the decode-order-timestamp
    /// defect: a degenerate `ctts` (absent, all-zero, or locally-constant-but-drifting) on a
    /// stream that actually carries B-slices. Fails open (`false`) on any parse failure or
    /// short read — a probe never crashes or blocks on this, it just misses the hazard.
    private static func detectDecodeOrderTimestampHazard(
        data: Data,
        stblRange: Range<Int>,
        firstStsdEntry: BoxHeader,
        reader: any RandomAccessReading
    ) async -> Bool {
        guard let avcC = findAvcC(data, stsdEntry: firstStsdEntry) else { return false }

        // Baseline profile H.264 (avcC[1] == AVCProfileIndication 66) is structurally
        // incapable of carrying B-slices, so it can never exhibit this hazard — skip the
        // sample reads the candidate path below would otherwise pay on every no-B camera/
        // screen recording.
        let profileIdcOffset = avcC.contentStart + 1
        guard profileIdcOffset < avcC.boxEnd, profileIdcOffset < data.count else { return false }
        if data[data.startIndex + profileIdcOffset] == 66 { return false }

        guard let nalLengthSize = avcCNalLengthSize(data, avcC: avcC) else { return false }

        guard let sttsBox = firstChildBox(data, type: "stts", in: stblRange) else { return false }
        let sttsEntries = parseStts(data, box: sttsBox)
        // Weighted argmax across runs (the same delta can span many runs), and no verdict on
        // genuine VFR — with no dominant cadence there is no meaningful spread threshold.
        var durationWeights: [UInt32: UInt64] = [:]
        for entry in sttsEntries {
            durationWeights[entry.sampleDelta, default: 0] += UInt64(entry.sampleCount)
        }
        let totalSttsSamples = durationWeights.values.reduce(0, +)
        guard let dominant = durationWeights.max(by: { $0.value < $1.value }),
              dominant.key > 0, dominant.value * 2 >= totalSttsSamples else {
            return false
        }
        let dominantDuration = dominant.key

        let analysis: DegeneracyAnalysis
        switch loadCtts(data, stblRange: stblRange) {
        case .absent:
            analysis = DegeneracyAnalysis(isCandidate: true, firstSampleIndex: 0)
        case .malformed:
            // A ctts box that exists but doesn't parse is a different signal than "no offsets
            // at all" — trusting it as evidence either way risks a false positive, so bail.
            return false
        case .parsed(let runs):
            analysis = analyzeCttsDegeneracy(runs: runs, dominantFrameDuration: dominantDuration)
        }
        guard analysis.isCandidate else { return false }
        guard !Task.isCancelled else { return false }

        guard let stszBox = firstChildBox(data, type: "stsz", in: stblRange),
              let sampleSizes = parseStsz(data, box: stszBox), sampleSizes.count > 0,
              analysis.firstSampleIndex < sampleSizes.count,
              let stscBox = firstChildBox(data, type: "stsc", in: stblRange),
              let stscEntries = parseStsc(data, box: stscBox),
              let chunkOffsets = parseChunkOffsets(data, stblRange: stblRange)
        else { return false }

        // Evidence must come from the window that was judged degenerate, not spill into a
        // possibly-healthy neighbor.
        let sampleCount = min(32, sampleSizes.count - analysis.firstSampleIndex)
        let ranges = sampleByteRanges(
            startIndex: analysis.firstSampleIndex, count: sampleCount,
            sampleSizes: sampleSizes, stscEntries: stscEntries, chunkOffsets: chunkOffsets
        )
        guard !ranges.isEmpty else { return false }

        return await confirmBSlices(reader: reader, nalLengthSize: nalLengthSize, ranges: ranges)
    }

    /// The `stbl`'s `stts` box: run-length (sample_count, sample_delta) pairs.
    private static func parseStts(_ data: Data, box: BoxHeader) -> [SttsEntry] {
        var entries: [SttsEntry] = []
        let start = box.contentStart + 4 // skip version/flags
        guard start + 4 <= box.boxEnd, start + 4 <= data.count else { return entries }
        let count = readUInt32BE(data, at: start)
        var offset = start + 4
        for _ in 0..<count {
            // A table that can't deliver its declared entries is malformed — fail open
            // (empty) rather than hand back a partial table that would skew the
            // dominant-frame-duration read (matches loadCtts/parseStsc/parseStsz).
            guard offset + 8 <= box.boxEnd, offset + 8 <= data.count else { return [] }
            entries.append(SttsEntry(sampleCount: readUInt32BE(data, at: offset), sampleDelta: readUInt32BE(data, at: offset + 4)))
            offset += 8
        }
        return entries
    }

    /// The `stbl`'s `ctts` box, if present: run-length (count, offset) pairs. The offset is
    /// read as SIGNED regardless of the box version — real-world v0 files carry negative
    /// values despite the spec reserving that for v1.
    private static func loadCtts(_ data: Data, stblRange: Range<Int>) -> CttsOutcome {
        guard let box = firstChildBox(data, type: "ctts", in: stblRange) else { return .absent }
        let start = box.contentStart + 4
        guard start + 4 <= box.boxEnd, start + 4 <= data.count else { return .malformed }
        let count = readUInt32BE(data, at: start)
        var offset = start + 4
        // A lying entry count can't allocate more than the box could physically hold.
        var runs: [CttsRun] = []
        runs.reserveCapacity(min(Int(count), max(0, box.boxEnd - offset) / 8))
        for _ in 0..<count {
            guard offset + 8 <= box.boxEnd, offset + 8 <= data.count else { return .malformed }
            let rawOffset = readUInt32BE(data, at: offset + 4)
            runs.append(CttsRun(count: readUInt32BE(data, at: offset), offset: Int32(bitPattern: rawOffset)))
            offset += 8
        }
        return .parsed(runs)
    }

    /// Walks the ctts runs in non-overlapping 32-sample windows without materializing a
    /// per-sample offset array — a window is degenerate when its offset spread is under
    /// half the dominant frame duration. Candidate when ≥50% of windows are degenerate
    /// (this also catches slow drift: a window's LOCAL spread stays tiny even while the
    /// value drifts by tens of thousands of ticks over the whole track).
    private static func analyzeCttsDegeneracy(runs: [CttsRun], dominantFrameDuration: UInt32) -> DegeneracyAnalysis {
        guard dominantFrameDuration > 0 else { return DegeneracyAnalysis(isCandidate: false, firstSampleIndex: 0) }
        let totalSamples = runs.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        // Untrusted run counts also bound the window loop below — a garbage table summing to
        // billions of samples would otherwise pin a CPU long past the probe's deadline.
        guard totalSamples > 0, totalSamples <= 8_000_000 else {
            return DegeneracyAnalysis(isCandidate: false, firstSampleIndex: 0)
        }

        let threshold = Double(dominantFrameDuration) / 2.0
        var windowCount = 0
        var degenerateCount = 0
        var firstDegenerateStart: Int?

        var runIndex = 0
        var runRemaining = runs[0].count
        var samplesProcessed: UInt64 = 0

        while samplesProcessed < totalSamples {
            let windowStart = samplesProcessed
            var remainingInWindow = min(UInt64(32), totalSamples - samplesProcessed)
            let windowSize = remainingInWindow
            var windowMin = Int64.max
            var windowMax = Int64.min

            while remainingInWindow > 0, runIndex < runs.count {
                if runRemaining == 0 {
                    runIndex += 1
                    if runIndex < runs.count { runRemaining = runs[runIndex].count }
                    continue
                }
                let value = Int64(runs[runIndex].offset)
                windowMin = min(windowMin, value)
                windowMax = max(windowMax, value)
                let consumed = min(UInt64(runRemaining), remainingInWindow)
                runRemaining -= UInt32(consumed)
                remainingInWindow -= consumed
            }

            windowCount += 1
            // A window that consumed no runs never updates windowMin/windowMax, and the
            // subtraction below would trap on the Int64 extremes — defensive, matches the
            // file's never-crash contract.
            guard windowMin <= windowMax else { return DegeneracyAnalysis(isCandidate: false, firstSampleIndex: 0) }
            if Double(windowMax - windowMin) < threshold {
                degenerateCount += 1
                if firstDegenerateStart == nil { firstDegenerateStart = Int(windowStart) }
            }
            samplesProcessed += windowSize
        }

        guard windowCount > 0 else { return DegeneracyAnalysis(isCandidate: false, firstSampleIndex: 0) }
        let isCandidate = Double(degenerateCount) / Double(windowCount) >= 0.5
        return DegeneracyAnalysis(isCandidate: isCandidate, firstSampleIndex: firstDegenerateStart ?? 0)
    }

    /// The `stbl`'s `stsz` box contents: either one fixed size shared by every sample, or a
    /// per-sample table. Kept out of a materialized `[UInt32]` for the fixed case — a hostile
    /// box can declare millions of samples at a fixed size in 20 bytes, and that shouldn't drive
    /// a multi-megabyte allocation just to answer "what size is sample N".
    private enum SampleSizes {
        case fixed(size: UInt32, count: Int)
        case table([UInt32])

        var count: Int {
            switch self {
            case .fixed(_, let count): return count
            case .table(let sizes): return sizes.count
            }
        }

        subscript(_ index: Int) -> UInt32 {
            switch self {
            case .fixed(let size, _): return size
            case .table(let sizes): return sizes[index]
            }
        }
    }

    /// The `stbl`'s `stsz` box: either one fixed size for every sample, or a per-sample table.
    /// `nil` on a truncated table — the caller fails the hazard check open rather than guess.
    private static func parseStsz(_ data: Data, box: BoxHeader) -> SampleSizes? {
        let start = box.contentStart + 4
        guard start + 8 <= box.boxEnd, start + 8 <= data.count else { return nil }
        let sampleSize = readUInt32BE(data, at: start)
        let sampleCount = Int(readUInt32BE(data, at: start + 4))
        // Sanity ceiling so a garbage count can't drive a giant allocation (the fixed-size
        // branch has no table bytes to bound it; ~74h of 30fps video stays well under this).
        guard sampleCount <= 8_000_000 else { return nil }
        if sampleSize != 0 { return .fixed(size: sampleSize, count: sampleCount) }

        var offset = start + 8
        var sizes: [UInt32] = []
        sizes.reserveCapacity(min(sampleCount, max(0, box.boxEnd - offset) / 4))
        for _ in 0..<sampleCount {
            guard offset + 4 <= box.boxEnd, offset + 4 <= data.count else { return nil }
            sizes.append(readUInt32BE(data, at: offset))
            offset += 4
        }
        return .table(sizes)
    }

    /// The `stbl`'s `stsc` box: (first_chunk, samples_per_chunk) run entries, 1-based chunk
    /// numbering. `nil` on a truncated table.
    private static func parseStsc(_ data: Data, box: BoxHeader) -> [StscEntry]? {
        let start = box.contentStart + 4
        guard start + 4 <= box.boxEnd, start + 4 <= data.count else { return nil }
        let count = Int(readUInt32BE(data, at: start))
        var offset = start + 4
        var entries: [StscEntry] = []
        entries.reserveCapacity(min(count, max(0, box.boxEnd - offset) / 12))
        for _ in 0..<count {
            guard offset + 12 <= box.boxEnd, offset + 12 <= data.count else { return nil }
            entries.append(StscEntry(firstChunk: readUInt32BE(data, at: offset), samplesPerChunk: readUInt32BE(data, at: offset + 4)))
            offset += 12
        }
        guard !entries.isEmpty else { return nil }
        return entries
    }

    /// The `stbl`'s chunk offset table — `stco` (32-bit) or `co64` (64-bit), whichever is
    /// present. `nil` if neither parses cleanly.
    private static func parseChunkOffsets(_ data: Data, stblRange: Range<Int>) -> [UInt64]? {
        if let stco = firstChildBox(data, type: "stco", in: stblRange) {
            let start = stco.contentStart + 4
            guard start + 4 <= stco.boxEnd, start + 4 <= data.count else { return nil }
            let count = Int(readUInt32BE(data, at: start))
            var offset = start + 4
            var offsets: [UInt64] = []
            offsets.reserveCapacity(min(count, max(0, stco.boxEnd - offset) / 4))
            for _ in 0..<count {
                guard offset + 4 <= stco.boxEnd, offset + 4 <= data.count else { return nil }
                offsets.append(UInt64(readUInt32BE(data, at: offset)))
                offset += 4
            }
            return offsets
        }
        if let co64 = firstChildBox(data, type: "co64", in: stblRange) {
            let start = co64.contentStart + 4
            guard start + 4 <= co64.boxEnd, start + 4 <= data.count else { return nil }
            let count = Int(readUInt32BE(data, at: start))
            var offset = start + 4
            var offsets: [UInt64] = []
            offsets.reserveCapacity(min(count, max(0, co64.boxEnd - offset) / 8))
            for _ in 0..<count {
                guard offset + 8 <= co64.boxEnd, offset + 8 <= data.count else { return nil }
                offsets.append(readUInt64BE(data, at: offset))
                offset += 8
            }
            return offsets
        }
        return nil
    }

    /// Locates the byte range of up to `count` consecutive decode-order samples starting at
    /// `startIndex`, by walking chunks in order and summing sample sizes within each chunk.
    private static func sampleByteRanges(
        startIndex: Int, count: Int,
        sampleSizes: SampleSizes, stscEntries: [StscEntry], chunkOffsets: [UInt64]
    ) -> [(offset: UInt64, size: UInt32)] {
        guard startIndex >= 0, startIndex < sampleSizes.count, count > 0, !chunkOffsets.isEmpty else { return [] }

        var results: [(offset: UInt64, size: UInt32)] = []
        results.reserveCapacity(count)

        var sampleIndex = 0
        var stscPos = 0
        for chunkNumber in 1...chunkOffsets.count {
            while stscPos + 1 < stscEntries.count, UInt32(chunkNumber) >= stscEntries[stscPos + 1].firstChunk {
                stscPos += 1
            }
            let samplesInChunk = Int(stscEntries[stscPos].samplesPerChunk)
            guard samplesInChunk > 0 else { continue }

            var runningOffset = chunkOffsets[chunkNumber - 1]
            for _ in 0..<samplesInChunk {
                guard sampleIndex < sampleSizes.count else { break }
                let size = sampleSizes[sampleIndex]
                if sampleIndex >= startIndex, results.count < count {
                    results.append((runningOffset, size))
                }
                let (next, overflow) = runningOffset.addingReportingOverflow(UInt64(size))
                guard !overflow else { return results } // garbage chunk offset table
                runningOffset = next
                sampleIndex += 1
                if results.count >= count { return results }
            }
        }
        return results
    }

    /// The NAL length-prefix size from an already-located `avcC` box: the lower 2 bits of
    /// configuration byte 4, plus one. `nil` if `avcC` is too short to read.
    private static func avcCNalLengthSize(_ data: Data, avcC: BoxHeader) -> Int? {
        let lengthByteOffset = avcC.contentStart + 4
        guard lengthByteOffset < avcC.boxEnd, lengthByteOffset < data.count else { return nil }
        let byte = data[data.startIndex + lengthByteOffset]
        return Int(byte & 0x03) + 1
    }

    // MARK: - additional structural hazards (in-band params, interlace, multiple stsd, missing SPS)

    /// Sample-entry tags where the parameter sets ride in-band with the samples instead of in
    /// `avcC`/`hvcC`/`dvcC` — AVFoundation only accepts the out-of-band form.
    private static let inBandParameterSetFourccs: Set<String> = ["hev1", "avc3", "avc4", "dvhe"]

    /// Computes every structural hazard for the first video trak in one place: the two that
    /// only need the raw fourcc/entry-count (checked unconditionally), and the avcC/hvcC-backed
    /// ones (checked only when the sample table resolved far enough to read them). A file can
    /// carry several at once, hence a `Set` union rather than an early return.
    private static func detectVideoTrakHazards(
        data: Data,
        firstFourcc: String,
        mappedCodec: VideoCodec?,
        sampleEntryCount: Int,
        stblRange: Range<Int>?,
        firstStsdEntry: BoxHeader?,
        reader: any RandomAccessReading
    ) async -> Set<AVPlayerHazard> {
        var hazards: Set<AVPlayerHazard> = []

        if inBandParameterSetFourccs.contains(firstFourcc) {
            hazards.insert(.inBandParameterSets)
        }
        if sampleEntryCount > 1 {
            hazards.insert(.multipleSampleDescriptions)
        }

        guard let stblRange, let firstStsdEntry else { return hazards }

        if firstFourcc == "avc1" {
            if detectMissingParameterSetsHazard(data, stsdEntry: firstStsdEntry) {
                hazards.insert(.missingParameterSets)
            }
            if detectInterlacedH264Hazard(data, stsdEntry: firstStsdEntry) {
                hazards.insert(.interlacedVideo)
            }
        } else if firstFourcc == "hvc1" || firstFourcc == "dvh1" {
            if detectInterlacedHevcHazard(data, stsdEntry: firstStsdEntry) {
                hazards.insert(.interlacedVideo)
            }
        }

        // Only h264 carries the decode-order hazard; HEVC is out of scope.
        if mappedCodec == .h264 {
            let hasDecodeOrderHazard = await detectDecodeOrderTimestampHazard(
                data: data, stblRange: stblRange, firstStsdEntry: firstStsdEntry, reader: reader
            )
            if hasDecodeOrderHazard { hazards.insert(.decodeOrderTimestamps) }
        }

        return hazards
    }

    /// Locates the sample entry's nested `avcC` box, past the fixed 78-byte VisualSampleEntry
    /// header shared by every video sample entry type: SampleEntry(8) + pre_defined/reserved/
    /// pre_defined/width/height/resolution×2/reserved/frame_count/compressorname/depth/
    /// pre_defined(70) = 78 bytes.
    private static func findAvcC(_ data: Data, stsdEntry: BoxHeader) -> BoxHeader? {
        let childStart = stsdEntry.contentStart + 78
        guard childStart <= stsdEntry.boxEnd else { return nil }
        return firstChildBox(data, type: "avcC", in: childStart..<stsdEntry.boxEnd)
    }

    /// Locates the sample entry's nested `hvcC` box, past the same 78-byte fixed header as
    /// `findAvcC` (every video sample entry shares that layout regardless of codec).
    private static func findHvcC(_ data: Data, stsdEntry: BoxHeader) -> BoxHeader? {
        let childStart = stsdEntry.contentStart + 78
        guard childStart <= stsdEntry.boxEnd else { return nil }
        return firstChildBox(data, type: "hvcC", in: childStart..<stsdEntry.boxEnd)
    }

    /// Reads `avcC`'s SPS count (byte 5, low 5 bits) and, when there's at least one, the raw
    /// bytes of the first SPS NAL unit (each stored as a 2-byte BE length prefix + NAL bytes,
    /// starting at byte 6). The count is always returned when readable; the NAL is `nil` if the
    /// count is zero or the length/bytes don't fit — callers that only need the count (missing
    /// parameter sets) don't need the NAL to be present.
    private static func avcCSPSInfo(_ data: Data, avcC: BoxHeader) -> (count: UInt8, firstNAL: Data?)? {
        let countOffset = avcC.contentStart + 5
        guard countOffset < avcC.boxEnd, countOffset < data.count else { return nil }
        let numOfSPS = data[data.startIndex + countOffset] & 0x1F
        guard numOfSPS > 0 else { return (numOfSPS, nil) }

        let lengthOffset = avcC.contentStart + 6
        guard lengthOffset + 2 <= avcC.boxEnd, lengthOffset + 2 <= data.count else { return (numOfSPS, nil) }
        let spsLength = Int(data[data.startIndex + lengthOffset]) << 8 | Int(data[data.startIndex + lengthOffset + 1])
        let spsStart = lengthOffset + 2
        guard spsLength > 0, spsStart + spsLength <= avcC.boxEnd, spsStart + spsLength <= data.count else {
            return (numOfSPS, nil)
        }
        let nal = data.subdata(in: (data.startIndex + spsStart)..<(data.startIndex + spsStart + spsLength))
        return (numOfSPS, nal)
    }

    /// `.missingParameterSets`: `avcC[5] & 0x1F == 0` is a guaranteed decoder failure (-8971).
    /// Fails open (no hazard) if `avcC` itself is missing or too short — absence of the box
    /// alone isn't proof, only a readable zero count is.
    private static func detectMissingParameterSetsHazard(_ data: Data, stsdEntry: BoxHeader) -> Bool {
        guard let avcC = findAvcC(data, stsdEntry: stsdEntry),
              let info = avcCSPSInfo(data, avcC: avcC)
        else { return false }
        return info.count == 0
    }

    /// `.interlacedVideo` for H.264: bit-parses the first SPS out of `avcC` for
    /// `frame_mbs_only_flag`. Fails open on any missing/truncated data.
    private static func detectInterlacedH264Hazard(_ data: Data, stsdEntry: BoxHeader) -> Bool {
        guard let avcC = findAvcC(data, stsdEntry: stsdEntry),
              let info = avcCSPSInfo(data, avcC: avcC),
              let nal = info.firstNAL, nal.count > 1
        else { return false }
        // drop the 1-byte NAL header
        let rbsp = H264BitstreamReader.removeEmulationPrevention(Array(nal.dropFirst()))
        return H264BitstreamReader.spsIsFieldCoded(rbsp)
    }

    /// `.interlacedVideo` for HEVC: `hvcC` byte 6 carries `general_progressive_source_flag`
    /// (0x80) and `general_interlaced_source_flag` (0x40) — hazard iff interlaced is set and
    /// progressive is clear. Fails open on any missing/short data.
    private static func detectInterlacedHevcHazard(_ data: Data, stsdEntry: BoxHeader) -> Bool {
        guard let hvcC = findHvcC(data, stsdEntry: stsdEntry) else { return false }
        let flagsOffset = hvcC.contentStart + 6
        guard flagsOffset < hvcC.boxEnd, flagsOffset < data.count else { return false }
        let byte = data[data.startIndex + flagsOffset]
        let progressive = byte & 0x80 != 0
        let interlaced = byte & 0x40 != 0
        return interlaced && !progressive
    }

    /// Looks for a B-slice NAL in each sample's leading bytes (capped at 4 KiB per sample),
    /// under a total byte budget. Consecutive samples in a chunk are contiguous on disk, so a
    /// span that fits entirely within the remaining budget is pulled in one bulk read — a slow
    /// link sees a handful of round trips, not one per sample. A span that DOESN'T fit (a single
    /// high-bitrate sample can be several hundred KB, eating the whole budget on its own) falls
    /// back to reading each sample's own head individually instead — otherwise sample 0 alone
    /// would exhaust the budget and every later sample in the span would go unexamined. Stops at
    /// the first B; any read failure just moves on.
    private static func confirmBSlices(
        reader: any RandomAccessReading, nalLengthSize: Int, ranges: [(offset: UInt64, size: UInt32)]
    ) async -> Bool {
        var byteBudget = 262_144

        var spanStart = 0
        while spanStart < ranges.count, byteBudget > 0 {
            guard !Task.isCancelled else { return false }

            var spanEnd = spanStart + 1
            var spanLength = UInt64(ranges[spanStart].size)
            while spanEnd < ranges.count,
                  ranges[spanEnd].offset == ranges[spanStart].offset + spanLength {
                spanLength += UInt64(ranges[spanEnd].size)
                spanEnd += 1
            }

            if spanLength <= UInt64(byteBudget) {
                let readLength = Int(spanLength)
                byteBudget -= readLength
                if readLength > 0,
                   let bytes = try? await reader.read(offset: ranges[spanStart].offset, length: readLength),
                   !bytes.isEmpty {
                    for range in ranges[spanStart..<spanEnd] {
                        let local = Int(range.offset - ranges[spanStart].offset)
                        guard local < bytes.count else { break } // short read cut the span short
                        let available = min(Int(range.size), 4096, bytes.count - local)
                        let sample = bytes[(bytes.startIndex + local)..<(bytes.startIndex + local + available)]
                        if H264BitstreamReader.containsBSlice(sample, nalLengthSize: nalLengthSize) { return true }
                    }
                }
            } else {
                for range in ranges[spanStart..<spanEnd] {
                    guard !Task.isCancelled else { return false }
                    guard byteBudget > 0 else { break }
                    let readLength = min(Int(range.size), 4096, byteBudget)
                    guard readLength > 0 else { continue }
                    byteBudget -= readLength
                    if let bytes = try? await reader.read(offset: range.offset, length: readLength),
                       !bytes.isEmpty,
                       H264BitstreamReader.containsBSlice(bytes, nalLengthSize: nalLengthSize) {
                        return true
                    }
                }
            }
            spanStart = spanEnd
        }
        return false
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

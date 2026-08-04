import Foundation
import ParallaxCore

/// Byte-level ISO BMFF (MP4/MOV) fixture builders for container-probe suites.
///
/// `MediaProbe` reads real files over SMB, so its tests feed it real box trees — hand-assembled
/// here rather than as binary fixtures, so a case reads as "an mp4 with an avc1 video trak"
/// instead of an opaque blob. Shared so the box builders exist once for every probe suite.
public enum ISOBMFFFixtures {
    /// A standard 32-bit-size box: `size(4) + type(4) + payload`.
    public static func box(_ type: String, _ payload: Data = Data()) -> Data {
        var data = Data()
        var size = UInt32(8 + payload.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    /// A box using the `size == 1` largesize encoding: `1(4) + type(4) + size64(8) + payload`.
    public static func largesizeBox(_ type: String, _ payload: Data = Data()) -> Data {
        var data = Data()
        var size32 = UInt32(1).bigEndian
        withUnsafeBytes(of: &size32) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        var largesize = UInt64(16 + payload.count).bigEndian
        withUnsafeBytes(of: &largesize) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// A box declaring `size == 0`, i.e. "extends to end of file" — legal ISO BMFF for the last
    /// top-level box.
    public static func extendsToEOFBox(_ type: String, _ payload: Data = Data()) -> Data {
        var data = Data([0, 0, 0, 0])
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    /// A raw, deliberately arbitrary box header — crafts an overrunning or malformed header
    /// without materializing gigabytes of payload.
    public static func rawBoxHeader(type: String, size32: UInt32, largesize: UInt64) -> Data {
        var data = Data()
        var size = size32.bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        var large = largesize.bigEndian
        withUnsafeBytes(of: &large) { data.append(contentsOf: $0) }
        return data
    }

    /// An `ftyp` box with the given major brand. `"qt  "` sniffs as MOV, anything else as MP4.
    public static func ftyp(brand: String = "isom") -> Data {
        box("ftyp", Data(brand.utf8) + Data(count: 8))
    }

    /// An `stsd` box: version/flags(4) + entry_count(4) + one nested box per entry, whose TYPE is
    /// the codec fourcc. `MediaProbe` only reads the fourcc, so an empty entry payload suffices.
    public static func stsd(entries: [String]) -> Data {
        var payload = Data([0, 0, 0, 0])
        var count = UInt32(entries.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for entry in entries { payload.append(box(entry)) }
        return box("stsd", payload)
    }

    /// `mdia { hdlr, minf → stbl → stsd }` — the trak payload the probe walks. `handler` is the
    /// hdlr fourcc that tags the track kind ("vide" / "soun").
    public static func trakContent(stsdEntries: [String], handler: String) -> Data {
        var hdlr = Data(count: 8)                  // version/flags(4) + pre_defined(4)
        hdlr.append(Data(handler.utf8))
        hdlr.append(Data(count: 13))               // reserved(12) + name(1)
        return box("mdia", box("hdlr", hdlr) + box("minf", box("stbl", stsd(entries: stsdEntries))))
    }

    public static func trak(stsdEntries: [String], handler: String) -> Data {
        box("trak", trakContent(stsdEntries: stsdEntries, handler: handler))
    }

    /// The same `mdia { hdlr, minf → stbl → stsd }` shape as `trakContent`, but for fully-formed
    /// stsd entry boxes (e.g. `avcVideoSampleEntry`/`hevcVideoSampleEntry`) rather than
    /// `stsd(entries:)`'s codec-fourcc-only placeholders — for fixtures that need a real nested
    /// `avcC`/`hvcC` the probe reads, without the full sample-table machinery `h264TrakContent`
    /// builds for the decode-order hazard suite.
    private static func trakContentRaw(stsdEntries: [Data], handler: String) -> Data {
        var hdlr = Data(count: 8)
        hdlr.append(Data(handler.utf8))
        hdlr.append(Data(count: 13))
        return box("mdia", box("hdlr", hdlr) + box("minf", box("stbl", stsdRaw(entries: stsdEntries))))
    }

    public static func trakRaw(stsdEntries: [Data], handler: String) -> Data {
        box("trak", trakContentRaw(stsdEntries: stsdEntries, handler: handler))
    }

    /// The same trak content wrapped in a largesize header instead of a 32-bit one.
    public static func trakLargesize(stsdEntries: [String], handler: String) -> Data {
        largesizeBox("trak", trakContent(stsdEntries: stsdEntries, handler: handler))
    }

    /// A complete, well-formed MP4/MOV: `ftyp + moov(traks) + mdat`.
    public static func mp4(
        brand: String = "isom",
        traks: [Data],
        mdatByteCount: Int = 64,
        moovAfterMdat: Bool = false
    ) -> Data {
        let moov = box("moov", traks.reduce(into: Data()) { $0.append($1) })
        let mdat = box("mdat", Data(count: mdatByteCount))
        return ftyp(brand: brand) + (moovAfterMdat ? mdat + moov : moov + mdat)
    }

    // MARK: - Decode-order timestamp hazard fixtures (stts/ctts/stsz/stsc/stco + real h264 samples)

    /// An `stsd` entry box list where each entry is already a fully-formed box (as opposed to
    /// `stsd(entries:)`'s codec-fourcc-only placeholders) — needed for `avcVideoSampleEntry`,
    /// which carries a real `avcC` child the hazard probe reads.
    private static func stsdRaw(entries: [Data]) -> Data {
        var payload = Data([0, 0, 0, 0])
        var count = UInt32(entries.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for entry in entries { payload.append(entry) }
        return box("stsd", payload)
    }

    /// `avcC`: fixed configuration bytes, `lengthSizeMinusOne` in the low 2 bits of byte 4, plus
    /// zero or more SPS NAL units (each a 2-byte BE length prefix + the NAL bytes) — the fields
    /// `MediaProbe`'s NAL-length, missing-parameter-set, interlace, and Baseline-profile-skip
    /// hazard checks all read. Defaults to one benign progressive baseline SPS so fixtures that
    /// don't care about SPS content (e.g. the decode-order hazard suite) don't accidentally trip
    /// the SPS-based hazards; pass `spsNALs: []` for a "missing parameter sets" fixture.
    private static func avcC(
        nalLengthSizeMinusOne: UInt8 = 3,
        spsNALs: [Data] = [h264SPS(profileIdc: 66, frameMbsOnlyFlag: 1)]
    ) -> Data {
        // AVCProfileIndication mirrors the profile_idc actually encoded in the first SPS (its
        // first byte after the 1-byte NAL header) — `MediaProbe` reads this container field
        // directly for the Baseline-profile skip, so it can't be a fixed stand-in value.
        let profileIndication: UInt8 = spsNALs.first.flatMap { $0.count > 1 ? $0[$0.startIndex + 1] : nil } ?? 0x64
        var payload = Data([1, profileIndication, 0, 0x1F])          // version, profile, compat, level
        payload.append(0xFC | (nalLengthSizeMinusOne & 0x03))        // reserved(6) + lengthSizeMinusOne(2)
        payload.append(0xE0 | UInt8(spsNALs.count & 0x1F))           // reserved(3) + numOfSPS(5)
        for sps in spsNALs {
            var length = UInt16(sps.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(sps)
        }
        payload.append(0)                                            // numOfPictureParameterSets = 0 (unread)
        return box("avcC", payload)
    }

    /// A `stsd` video sample entry (`avc1`) with the real 78-byte VisualSampleEntry fixed header
    /// `MediaProbe` skips over to find the nested `avcC`.
    public static func avcVideoSampleEntry(
        nalLengthSizeMinusOne: UInt8 = 3,
        spsNALs: [Data] = [h264SPS(profileIdc: 66, frameMbsOnlyFlag: 1)]
    ) -> Data {
        var payload = Data(count: 78)
        payload.append(avcC(nalLengthSizeMinusOne: nalLengthSizeMinusOne, spsNALs: spsNALs))
        return box("avc1", payload)
    }

    /// `hvcC` with `general_progressive_source_flag`/`general_interlaced_source_flag` set in
    /// byte 6 of the `general_constraint_indicator_flags` field — the byte `MediaProbe`'s HEVC
    /// interlace check reads. The rest of the fixed hvcC layout is zeroed; nothing else is read.
    private static func hvcC(constraintByte6: UInt8) -> Data {
        var payload = Data(count: 6)                                 // version + profile byte + compat flags(4)
        payload.append(constraintByte6)
        payload.append(Data(count: 15))                              // rest of the fixed hvcC fields, unread
        return box("hvcC", payload)
    }

    /// A `stsd` video sample entry (`hvc1`/`dvh1`) with the real 78-byte VisualSampleEntry fixed
    /// header, carrying a nested `hvcC` for the HEVC interlace hazard check.
    public static func hevcVideoSampleEntry(type: String = "hvc1", constraintByte6: UInt8) -> Data {
        var payload = Data(count: 78)
        payload.append(hvcC(constraintByte6: constraintByte6))
        return box(type, payload)
    }

    /// A raw H.264 SPS NAL (1-byte NAL header, type 7, + RBSP) for interlace-hazard fixtures.
    /// Bit-packs just the fields `MediaProbe`'s SPS parser reads, leaving everything else at its
    /// simplest legal value. `profileIdc` in the "High" family also emits the chroma-format/
    /// bit-depth extension fields; `scalingMatrixPresent` exercises the deliberate parser bail;
    /// `truncated` cuts the bitstream short (right after `sps_id`) for the "fails open" case.
    public static func h264SPS(
        profileIdc: Int,
        frameMbsOnlyFlag: Int,
        scalingMatrixPresent: Bool = false,
        truncated: Bool = false
    ) -> Data {
        var bits: [UInt8] = []
        func appendFixed(_ value: Int, bitCount: Int) {
            for shift in stride(from: bitCount - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> shift) & 1))
            }
        }
        func appendUE(_ value: Int) { bits.append(contentsOf: expGolombBits(value)) }

        appendFixed(profileIdc, bitCount: 8)
        appendFixed(0, bitCount: 8)                    // constraint_set flags + reserved_zero_2bits
        appendFixed(0x1F, bitCount: 8)                  // level_idc
        appendUE(0)                                      // seq_parameter_set_id

        let isHighProfile = H264BitstreamReader.h264HighProfileIdcs.contains(profileIdc)
        if isHighProfile {
            appendUE(1)                                   // chroma_format_idc (4:2:0, skips separate_colour_plane_flag)
            appendUE(0)                                   // bit_depth_luma_minus8
            appendUE(0)                                   // bit_depth_chroma_minus8
            appendFixed(0, bitCount: 1)                    // qpprime_y_zero_transform_bypass_flag
            appendFixed(scalingMatrixPresent ? 1 : 0, bitCount: 1)
        }

        if !(isHighProfile && scalingMatrixPresent) {
            appendUE(0)                                   // log2_max_frame_num_minus4
            appendUE(0)                                   // pic_order_cnt_type == 0
            appendUE(0)                                   // log2_max_pic_order_cnt_lsb_minus4
            appendUE(0)                                   // max_num_ref_frames
            appendFixed(0, bitCount: 1)                    // gaps_in_frame_num_value_allowed_flag
            appendUE(0)                                   // pic_width_in_mbs_minus1
            appendUE(0)                                   // pic_height_in_map_units_minus1
            appendFixed(frameMbsOnlyFlag, bitCount: 1)
        }

        if truncated {
            // Cut well before frame_mbs_only_flag is reached (profile+constraints+level alone is
            // 24 bits) so the parser runs out of bits mid-field rather than reading a real value.
            bits = Array(bits.prefix(16))
        }

        var payload = Data([0x67])                       // NAL header: nal_ref_idc=3, type=7 (SPS)
        payload.append(packBits(bits))
        return payload
    }

    private static func sttsPayload(entries: [(count: UInt32, delta: UInt32)]) -> Data {
        var payload = Data([0, 0, 0, 0])
        var count = UInt32(entries.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for entry in entries {
            var c = entry.count.bigEndian
            withUnsafeBytes(of: &c) { payload.append(contentsOf: $0) }
            var d = entry.delta.bigEndian
            withUnsafeBytes(of: &d) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    /// Offsets are always written as SIGNED — `MediaProbe` reads them that way regardless of
    /// the box's declared version, matching real v0 files that carry negative offsets.
    private static func cttsPayload(entries: [(count: UInt32, offset: Int32)]) -> Data {
        var payload = Data([0, 0, 0, 0])
        var count = UInt32(entries.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for entry in entries {
            var c = entry.count.bigEndian
            withUnsafeBytes(of: &c) { payload.append(contentsOf: $0) }
            var o = UInt32(bitPattern: entry.offset).bigEndian
            withUnsafeBytes(of: &o) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    /// Variable-size table (`sample_size == 0`) — every fixture needs real per-sample sizes to
    /// locate sample byte ranges.
    private static func stszPayload(sizes: [UInt32]) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(Data(count: 4))                               // sample_size = 0
        var count = UInt32(sizes.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for size in sizes {
            var v = size.bigEndian
            withUnsafeBytes(of: &v) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    /// Fixed-size table (`sample_size != 0`, no per-sample entries) — exercises `MediaProbe`'s
    /// other `stsz` branch. Every sample in `sizes` must share the same size.
    private static func stszFixedPayload(sizes: [UInt32]) -> Data {
        let commonSize = sizes.first ?? 0
        precondition(sizes.allSatisfy { $0 == commonSize }, "a fixed-size stsz fixture needs uniform sample sizes")
        var payload = Data([0, 0, 0, 0])
        var size = commonSize.bigEndian
        withUnsafeBytes(of: &size) { payload.append(contentsOf: $0) }
        var count = UInt32(sizes.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        return payload
    }

    private static func stscPayload(entries: [(firstChunk: UInt32, samplesPerChunk: UInt32)]) -> Data {
        var payload = Data([0, 0, 0, 0])
        var count = UInt32(entries.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for entry in entries {
            var fc = entry.firstChunk.bigEndian
            withUnsafeBytes(of: &fc) { payload.append(contentsOf: $0) }
            var spc = entry.samplesPerChunk.bigEndian
            withUnsafeBytes(of: &spc) { payload.append(contentsOf: $0) }
            var sdi = UInt32(1).bigEndian
            withUnsafeBytes(of: &sdi) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    private static func stcoPayload(offsets: [UInt32]) -> Data {
        var payload = Data([0, 0, 0, 0])
        var count = UInt32(offsets.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for offset in offsets {
            var v = offset.bigEndian
            withUnsafeBytes(of: &v) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    /// `trak → mdia { hdlr, minf → stbl { stsd, stts, ctts?, stsz, stsc, stco } }` — the full
    /// sample-table shape the decode-order hazard detector reads. `cttsPayload == nil` omits
    /// the box entirely, for "no ctts at all" fixtures.
    private static func h264TrakContent(
        stsdEntry: Data,
        sttsPayload: Data,
        cttsPayload: Data?,
        stszPayload: Data,
        stscPayload: Data,
        stcoPayload: Data
    ) -> Data {
        var hdlr = Data(count: 8)
        hdlr.append(Data("vide".utf8))
        hdlr.append(Data(count: 13))

        var stblPayload = stsdRaw(entries: [stsdEntry])
        stblPayload.append(box("stts", sttsPayload))
        if let cttsPayload { stblPayload.append(box("ctts", cttsPayload)) }
        stblPayload.append(box("stsz", stszPayload))
        stblPayload.append(box("stsc", stscPayload))
        stblPayload.append(box("stco", stcoPayload))

        return box("mdia", box("hdlr", hdlr) + box("minf", box("stbl", stblPayload)))
    }

    /// A length-prefixed H.264 slice NAL: a type-1 (non-IDR) NAL header byte +
    /// `first_mb_in_slice=0` + `slice_type` as exp-Golomb fields, enough for the hazard probe's
    /// slice-header sniff.
    public static func h264Sample(nalLengthSize: Int, sliceType: Int) -> Data {
        var bits = expGolombBits(0)              // first_mb_in_slice
        bits.append(contentsOf: expGolombBits(sliceType))
        var payload = Data([1])                   // NAL header: type 1 (non-IDR slice)
        payload.append(packBits(bits))

        var sample = Data()
        let length = UInt32(payload.count)
        for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
            sample.append(UInt8((length >> shift) & 0xFF))
        }
        sample.append(payload)
        return sample
    }

    /// The three shapes a fixture's `ctts` box can take: not present at all, a well-formed
    /// run-length table, or deliberately truncated/garbage bytes (for the "unparseable ctts
    /// fails open" case — distinct from "absent", which is an automatic hazard candidate).
    public enum CttsFixture: Sendable {
        case absent
        case entries([(count: UInt32, offset: Int32)])
        case raw(Data)
    }

    /// The two `stsz` shapes `h264HazardMp4` can wire up: a per-sample table, or one fixed size
    /// shared by every sample (which requires `sampleData` to already be uniform-sized).
    public enum StszEncoding: Sendable {
        case table
        case fixed
    }

    /// Builds a complete MP4 with a single h264 video trak wired for the decode-order hazard
    /// probe: real sample bytes in `mdat`, and `stco` pointing at their true file offsets. By
    /// default every sample lands in one chunk; `samplesPerChunk` splits them across several
    /// equal-sized chunks (`sampleData.count` must be an exact multiple) to exercise the
    /// `stsc`/`stco` chunk walk. Defaults to a Main-profile (77) SPS — not Baseline (66), which
    /// can never carry a B-slice and would make the fixture's own B-slice samples nonsensical.
    public static func h264HazardMp4(
        nalLengthSize: Int = 4,
        sttsEntries: [(count: UInt32, delta: UInt32)],
        ctts: CttsFixture,
        sampleData: [Data],
        spsNALs: [Data] = [h264SPS(profileIdc: 77, frameMbsOnlyFlag: 1)],
        stszEncoding: StszEncoding = .table,
        samplesPerChunk: Int? = nil
    ) -> Data {
        let stsdEntry = avcVideoSampleEntry(nalLengthSizeMinusOne: UInt8(nalLengthSize - 1), spsNALs: spsNALs)
        let sampleSizes = sampleData.map { UInt32($0.count) }
        let stsz: Data
        switch stszEncoding {
        case .table: stsz = stszPayload(sizes: sampleSizes)
        case .fixed: stsz = stszFixedPayload(sizes: sampleSizes)
        }

        let chunkSampleCount = samplesPerChunk ?? sampleData.count
        precondition(
            chunkSampleCount > 0 && sampleData.count % chunkSampleCount == 0,
            "h264HazardMp4's samplesPerChunk must evenly divide sampleData.count"
        )
        let chunkCount = sampleData.count / chunkSampleCount
        let stsc = stscPayload(entries: [(firstChunk: 1, samplesPerChunk: UInt32(chunkSampleCount))])
        let chunkByteSizes: [Int] = (0..<chunkCount).map { chunkIndex in
            sampleData[(chunkIndex * chunkSampleCount)..<((chunkIndex + 1) * chunkSampleCount)]
                .reduce(0) { $0 + $1.count }
        }

        let cttsPayload: Data?
        switch ctts {
        case .absent: cttsPayload = nil
        case .entries(let entries): cttsPayload = self.cttsPayload(entries: entries)
        case .raw(let data): cttsPayload = data
        }
        let stts = sttsPayload(entries: sttsEntries)

        // Chunk offsets are absolute file offsets, so the header must be assembled once to
        // learn `mdat`'s start — the placeholder offsets don't change the header's byte
        // count, so a second, differently-valued build lands the sample bytes correctly.
        func moovBytes(stco: Data) -> Data {
            box("moov", box("trak", h264TrakContent(
                stsdEntry: stsdEntry, sttsPayload: stts, cttsPayload: cttsPayload,
                stszPayload: stsz, stscPayload: stsc, stcoPayload: stco
            )))
        }
        let placeholderOffsets = Array(repeating: UInt32(0), count: chunkCount)
        let placeholderHead = ftyp() + moovBytes(stco: stcoPayload(offsets: placeholderOffsets))
        let mdatStart = UInt32(placeholderHead.count) + 8            // + mdat's own 8-byte header
        var offsets: [UInt32] = []
        var runningOffset = mdatStart
        for chunkSize in chunkByteSizes {
            offsets.append(runningOffset)
            runningOffset += UInt32(chunkSize)
        }
        let head = ftyp() + moovBytes(stco: stcoPayload(offsets: offsets))

        let mdat = box("mdat", sampleData.reduce(into: Data()) { $0.append($1) })
        return head + mdat
    }

    private static func expGolombBits(_ value: Int) -> [UInt8] {
        let codeNum = value + 1
        var leadingZeroBits = 0
        while (1 << (leadingZeroBits + 1)) <= codeNum { leadingZeroBits += 1 }
        var bits: [UInt8] = Array(repeating: 0, count: leadingZeroBits)
        bits.append(1)
        if leadingZeroBits > 0 {
            let valueBits = codeNum - (1 << leadingZeroBits)
            for i in stride(from: leadingZeroBits - 1, through: 0, by: -1) {
                bits.append(UInt8((valueBits >> i) & 1))
            }
        }
        return bits
    }

    /// Packs an MSB-first bit sequence into bytes, right-padding the last byte with zero bits.
    private static func packBits(_ bits: [UInt8]) -> Data {
        var data = Data()
        var current: UInt8 = 0
        var bitCount = 0
        for bit in bits {
            current = (current << 1) | (bit & 1)
            bitCount += 1
            if bitCount == 8 {
                data.append(current)
                current = 0
                bitCount = 0
            }
        }
        if bitCount > 0 {
            current <<= (8 - bitCount)
            data.append(current)
        }
        return data
    }
}

/// A reader that reports a large `fileSize` and synthesizes bytes on demand.
///
/// Lets a suite exercise size-driven branches (the probe's 64 MiB `moov` cap) without
/// materializing that many bytes. `prefix` is served verbatim from offset 0; everything past it
/// reads as zeroes.
public struct SyntheticRandomAccessReader: RandomAccessReading {
    private let prefix: Data
    private let declaredSize: UInt64
    /// Bytes returned per read, capped below the requested length — models a short read at EOF
    /// or a chunked transport. Nil serves the full request.
    private let maxBytesPerRead: Int?

    public init(prefix: Data, declaredSize: UInt64, maxBytesPerRead: Int? = nil) {
        self.prefix = prefix
        self.declaredSize = declaredSize
        self.maxBytesPerRead = maxBytesPerRead
    }

    public var fileSize: UInt64 { get async throws { declaredSize } }

    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard offset < declaredSize, length > 0 else { return Data() }
        let wanted = min(length, maxBytesPerRead ?? length)
        let available = Int(min(UInt64(wanted), declaredSize - offset))
        var result = Data()
        for index in 0 ..< available {
            let absolute = Int(offset) + index
            result.append(absolute < prefix.count ? prefix[prefix.startIndex + absolute] : 0)
        }
        return result
    }
}

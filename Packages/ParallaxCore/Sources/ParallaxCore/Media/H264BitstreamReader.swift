import Foundation

/// H.264 (Annex B / avcC-style length-prefixed) bitstream primitives shared by `MediaProbe`'s
/// structural hazard checks: exp-Golomb bit reading, emulation-prevention removal, and
/// slice-type / SPS field parsing. `highProfileIdcs` is `package` so `ISOBMFFFixtures` (test
/// support) can build fixtures against the same profile list rather than duplicating it.
package enum H264BitstreamReader {
    /// H.264 profile ids that carry the chroma-format/bit-depth/scaling-matrix extension fields
    /// in their SPS (Annex A "High" family and friends).
    package static let h264HighProfileIdcs: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    /// Walks length-prefixed NALs in a raw Annex-B-less (avcC-style) sample buffer, checking
    /// slice type on type-1 (non-IDR) and type-5 (IDR) NALs.
    static func containsBSlice(_ bytes: Data, nalLengthSize: Int) -> Bool {
        guard (1...4).contains(nalLengthSize) else { return false }
        let base = bytes.startIndex
        var offset = base
        while offset + nalLengthSize <= bytes.endIndex {
            var length = 0
            for i in 0..<nalLengthSize { length = (length << 8) | Int(bytes[offset + i]) }
            let nalStart = offset + nalLengthSize
            guard length > 0, nalStart < bytes.endIndex else { break }
            let nalEnd = min(nalStart + length, bytes.endIndex) // tolerate a truncated final NAL

            let nalType = Int(bytes[nalStart] & 0x1F)
            if nalType == 1 || nalType == 5, let slice = parseSliceType(bytes, nalStart: nalStart, nalEnd: nalEnd),
               slice == 1 || slice == 6 {
                return true
            }
            offset = nalStart + length
        }
        return false
    }

    /// Reads `first_mb_in_slice` then `slice_type` from a slice header, after stripping
    /// emulation-prevention bytes from the first ~16 payload bytes.
    private static func parseSliceType(_ bytes: Data, nalStart: Int, nalEnd: Int) -> Int? {
        let payloadStart = nalStart + 1 // skip the 1-byte NAL header
        guard payloadStart < nalEnd else { return nil }
        let rawLength = min(16, nalEnd - payloadStart)
        let unescaped = removeEmulationPrevention(Array(bytes[payloadStart..<(payloadStart + rawLength)]))
        var bitReader = ExpGolombReader(bytes: unescaped)
        guard bitReader.readUE() != nil, let sliceType = bitReader.readUE() else { return nil }
        return sliceType
    }

    /// Strips `0x03` emulation-prevention bytes that follow two or more `0x00` bytes.
    static func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var zeroRun = 0
        for byte in bytes {
            if zeroRun >= 2, byte == 0x03 {
                zeroRun = 0
                continue
            }
            result.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return result
    }

    /// Bit-parses an SPS RBSP (emulation-prevention already stripped) far enough to read
    /// `frame_mbs_only_flag` — field-coded (interlaced) streams clear that bit, which
    /// AVFoundation's decode path can't handle. Bails with `false` (no hazard, not "confirmed
    /// progressive") on the `seq_scaling_matrix_present_flag` branch — scaling-list syntax isn't
    /// worth carrying for a rare shape — and on any parse failure/short read.
    static func spsIsFieldCoded(_ rbsp: [UInt8]) -> Bool {
        var reader = ExpGolombReader(bytes: rbsp)
        guard let profileIdc = reader.readBits(8),
              reader.readBits(8) != nil, // constraint_set flags + reserved_zero_2bits
              reader.readBits(8) != nil, // level_idc
              reader.readUE() != nil // seq_parameter_set_id
        else { return false }

        if h264HighProfileIdcs.contains(profileIdc) {
            guard let chromaFormatIdc = reader.readUE() else { return false }
            if chromaFormatIdc == 3, reader.readBits(1) == nil { return false } // separate_colour_plane_flag
            guard reader.readUE() != nil, // bit_depth_luma_minus8
                  reader.readUE() != nil, // bit_depth_chroma_minus8
                  reader.readBits(1) != nil, // qpprime_y_zero_transform_bypass_flag
                  let scalingMatrixPresent = reader.readBits(1)
            else { return false }
            if scalingMatrixPresent == 1 { return false } // deliberate bail, see doc comment
        }

        guard reader.readUE() != nil, // log2_max_frame_num_minus4
              let picOrderCntType = reader.readUE()
        else { return false }

        switch picOrderCntType {
        case 0:
            guard reader.readUE() != nil else { return false } // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            guard reader.readBits(1) != nil, // delta_pic_order_always_zero_flag
                  reader.readSE() != nil, // offset_for_non_ref_pic
                  reader.readSE() != nil, // offset_for_top_to_bottom_field
                  let numRefFramesInCycle = reader.readUE(), numRefFramesInCycle <= 255 // spec ceiling
            else { return false }
            for _ in 0..<numRefFramesInCycle {
                guard reader.readSE() != nil else { return false }
            }
        default:
            break
        }

        guard reader.readUE() != nil, // max_num_ref_frames
              reader.readBits(1) != nil, // gaps_in_frame_num_value_allowed_flag
              reader.readUE() != nil, // pic_width_in_mbs_minus1
              reader.readUE() != nil, // pic_height_in_map_units_minus1
              let frameMbsOnlyFlag = reader.readBits(1)
        else { return false }

        return frameMbsOnlyFlag == 0
    }

    /// Minimal MSB-first bit reader for H.264 exp-Golomb fields.
    private struct ExpGolombReader {
        private let bytes: [UInt8]
        private var bitPosition = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        private mutating func readBit() -> Int? {
            let byteIndex = bitPosition / 8
            guard byteIndex < bytes.count else { return nil }
            let bitIndex = 7 - (bitPosition % 8)
            bitPosition += 1
            return Int((bytes[byteIndex] >> bitIndex) & 1)
        }

        /// Reads an unsigned exp-Golomb value (`ue(v)`).
        mutating func readUE() -> Int? {
            var leadingZeros = 0
            while true {
                guard let bit = readBit() else { return nil }
                if bit == 1 { break }
                leadingZeros += 1
                guard leadingZeros <= 32 else { return nil } // malformed guard, not a real H.264 limit
            }
            var value = 0
            for _ in 0..<leadingZeros {
                guard let bit = readBit() else { return nil }
                value = (value << 1) | bit
            }
            return (1 << leadingZeros) - 1 + value
        }

        /// Reads `bitCount` bits as an unsigned fixed-width field (`u(n)`).
        mutating func readBits(_ bitCount: Int) -> Int? {
            guard bitCount > 0 else { return 0 }
            var value = 0
            for _ in 0..<bitCount {
                guard let bit = readBit() else { return nil }
                value = (value << 1) | bit
            }
            return value
        }

        /// Reads a signed exp-Golomb value (`se(v)`): `ue(v)` k maps to k/2 rounded toward the
        /// sign implied by its parity (odd → positive, even → negative or zero).
        mutating func readSE() -> Int? {
            guard let codeNum = readUE() else { return nil }
            return codeNum % 2 == 1 ? (codeNum + 1) / 2 : -(codeNum / 2)
        }
    }
}

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

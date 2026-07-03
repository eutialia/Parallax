import Testing
import Foundation
@testable import ParallaxCore

@Suite struct MediaProbeTests {
    private func box(_ type: String, _ payload: Data = Data()) -> Data {
        var d = Data()
        var size = UInt32(8 + payload.count).bigEndian
        withUnsafeBytes(of: &size) { d.append(contentsOf: $0) }
        d.append(type.data(using: .ascii)!)
        d.append(payload)
        return d
    }
    // stsd sample-entry helper: visual/audio entries are just nested boxes whose
    // type is the codec fourcc — MediaProbe only reads the fourcc, so an empty
    // payload beyond the 8-byte stsd version/count header is enough:
    private func stsd(entries: [String]) -> Data {
        var payload = Data([0,0,0,0])                       // version+flags
        var count = UInt32(entries.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for e in entries { payload.append(box(e)) }
        return box("stsd", payload)
    }
    // hdlr payload: version/flags(4) + predefined(4) + handler fourcc(4) + reserved(12) + name(1)
    private func trakContent(stsdEntries: [String], handler: String) -> Data {
        var hdlr = Data(count: 8); hdlr.append(handler.data(using: .ascii)!); hdlr.append(Data(count: 13))
        return box("mdia", box("hdlr", hdlr) + box("minf", box("stbl", stsd(entries: stsdEntries))))
    }
    private func trak(stsdEntries: [String], handler: String) -> Data {
        box("trak", trakContent(stsdEntries: stsdEntries, handler: handler))
    }
    /// Same trak content as `trak(stsdEntries:handler:)` but wrapped with a
    /// `size == 1` largesize header instead of the regular 32-bit size.
    private func trakLargesize(stsdEntries: [String], handler: String) -> Data {
        largesizeBox("trak", trakContent(stsdEntries: stsdEntries, handler: handler))
    }
    /// Box header using the ISO BMFF `size == 1` largesize encoding: 4-byte
    /// size field fixed at 1, 4-byte type, 8-byte big-endian total box size.
    private func largesizeBox(_ type: String, _ payload: Data = Data()) -> Data {
        var d = Data()
        var size32 = UInt32(1).bigEndian
        withUnsafeBytes(of: &size32) { d.append(contentsOf: $0) }
        d.append(type.data(using: .ascii)!)
        var largesize = UInt64(16 + payload.count).bigEndian
        withUnsafeBytes(of: &largesize) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }
    /// A raw, deliberately malformed box header: `size == 1` with an arbitrary
    /// largesize and no trailing payload — used to craft an overrunning header
    /// without materializing gigabytes of fixture data.
    private func rawBoxHeader(type: String, size32: UInt32, largesize: UInt64) -> Data {
        var d = Data()
        var size = size32.bigEndian
        withUnsafeBytes(of: &size) { d.append(contentsOf: $0) }
        d.append(type.data(using: .ascii)!)
        var large = largesize.bigEndian
        withUnsafeBytes(of: &large) { d.append(contentsOf: $0) }
        return d
    }

    @Test func completeMp4H264AacIsCompleteAndKnown() async throws {
        let moov = box("moov", trak(stsdEntries: ["avc1"], handler: "vide") + trak(stsdEntries: ["mp4a"], handler: "soun"))
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + moov + box("mdat", Data(count: 64))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.container == .mp4)
        #expect(r.videoCodec == .known(.h264))
        #expect(r.audioCodec == .known(.aac))
        #expect(r.isComplete)
    }

    @Test func truncatedMdatIsIncomplete() async throws {
        let moov = box("moov", trak(stsdEntries: ["avc1"], handler: "vide"))
        var file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + moov
        // mdat header declaring 1 MiB, but only 16 bytes actually present
        var size = UInt32(1_048_576).bigEndian
        withUnsafeBytes(of: &size) { file.append(contentsOf: $0) }
        file.append("mdat".data(using: .ascii)!)
        file.append(Data(count: 16))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(!r.isComplete)
    }

    @Test func missingMoovIsIncomplete() async throws {
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + box("mdat", Data(count: 64))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(!r.isComplete)
    }

    @Test func moovAfterMdatIsFoundAndComplete() async throws {
        let moov = box("moov", trak(stsdEntries: ["hvc1"], handler: "vide") + trak(stsdEntries: ["ec-3"], handler: "soun"))
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + box("mdat", Data(count: 512)) + moov
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.videoCodec == .known(.hevc))
        #expect(r.audioCodec == .known(.eac3))
        #expect(r.isComplete)
    }

    @Test func unknownVideoFourccReportsUnknown() async throws {
        let moov = box("moov", trak(stsdEntries: ["mp4v"], handler: "vide"))
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + moov + box("mdat", Data(count: 8))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.videoCodec == .unknown)
    }

    @Test func worstCaseAudioWinsForMultiTrack() async throws {
        // aac + dts: selector must see dts so the whole file routes VLC and keeps both tracks.
        let moov = box("moov", trak(stsdEntries: ["avc1"], handler: "vide")
            + trak(stsdEntries: ["mp4a"], handler: "soun") + trak(stsdEntries: ["dtsc"], handler: "soun"))
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + moov + box("mdat", Data(count: 8))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.audioCodec == .known(.dts))
    }

    @Test func ebmlMagicIsMkv() async throws {
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: Data([0x1A,0x45,0xDF,0xA3]) + Data(count: 64)))
        #expect(r.container == .mkv)
        #expect(r.isComplete)
    }

    @Test func unknownMagicIsNilContainer() async throws {
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: Data(count: 64)))
        #expect(r.container == nil)
    }

    @Test func qtBrandIsMov() async throws {
        let moov = box("moov", trak(stsdEntries: ["avc1"], handler: "vide"))
        let file = box("ftyp", "qt  ".data(using: .ascii)! + Data(count: 8)) + moov + box("mdat", Data(count: 8))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.container == .mov)
    }

    // MARK: - nested-box overflow hardening (review round 1)

    @Test func nestedBoxWithHugeLargesizeDoesNotCrashAndDegrades() async throws {
        // A crafted trak header: size == 1 with a largesize near Int.max, so
        // `offset + boxSize` would trap a plain Int addition. Must degrade
        // instead of crashing — the malformed trak is simply never recognized.
        let malformedTrak = rawBoxHeader(type: "trak", size32: 1, largesize: UInt64(Int.max) - 4)
        let moov = box("moov", malformedTrak)
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + moov + box("mdat", Data(count: 8))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.videoCodec == .none)
        #expect(r.audioCodec == .none)
    }

    @Test func largesizeEncodedNestedBoxParsesCorrectly() async throws {
        // Happy path for the size == 1 largesize encoding on a NESTED box
        // (the trak inside moov), not just the already-covered top-level walk.
        let moov = box("moov", trakLargesize(stsdEntries: ["avc1"], handler: "vide"))
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + moov + box("mdat", Data(count: 8))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.videoCodec == .known(.h264))
    }

    // MARK: - unrecognized audio fourcc must not be silently dropped (review round 1)

    @Test func unrecognizedAudioFourccAmongKnownOnesIsUnknown() async throws {
        let moov = box("moov", trak(stsdEntries: ["mp4a", "zzzz"], handler: "soun"))
        let file = box("ftyp", "isom".data(using: .ascii)! + Data(count: 8)) + moov + box("mdat", Data(count: 8))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: file))
        #expect(r.audioCodec == .unknown)
    }

    // MARK: - container-sniff coverage (review round 1)

    @Test func riffAviMagicIsAvi() async throws {
        var data = "RIFF".data(using: .ascii)!
        data.append(Data(count: 4)) // RIFF chunk size field, unread by the sniff
        data.append("AVI ".data(using: .ascii)!)
        data.append(Data(count: 64))
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: data))
        #expect(r.container == .avi)
        #expect(r.isComplete)
    }

    @Test func tsSyncBytesMagicIsTs() async throws {
        var data = Data(count: 377)
        data[data.startIndex] = 0x47
        data[data.startIndex + 188] = 0x47
        data[data.startIndex + 376] = 0x47
        let r = try await MediaProbe.probe(InMemoryRandomAccessReader(data: data))
        #expect(r.container == .ts)
        #expect(r.isComplete)
    }
}

import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

/// One decode-order-timestamp hazard row: a ctts shape plus whether a B slice sits in the
/// sample window the probe reads, and the hazard verdict that combination should produce.
struct HazardCase: Sendable, CustomTestStringConvertible {
    let name: String
    let ctts: ISOBMFFFixtures.CttsFixture
    /// Sample index (of 64) that gets a B slice; `nil` means every sample is P/I.
    let bSliceIndex: Int?
    let expectedHazard: Bool
    var testDescription: String { name }
}

private let hazardCases: [HazardCase] = [
    HazardCase(
        name: "piecewise-constant ctts + a B slice → hazard",
        ctts: .entries([(count: 32, offset: 0), (count: 32, offset: 1)]),
        bSliceIndex: 5, expectedHazard: true
    ),
    // The real defect's exact shape: the offset climbs one tick every few samples, so it
    // drifts across the track while any 32-sample window spreads ~6 ticks — far under the
    // half-frame threshold (500 here), so every window reads degenerate.
    HazardCase(
        name: "slowly drifting ctts + a B slice → hazard",
        ctts: .entries((0..<16).map { (count: UInt32(4), offset: Int32($0)) }),
        bSliceIndex: 5, expectedHazard: true
    ),
    HazardCase(
        name: "no ctts at all + a B slice → hazard",
        ctts: .absent,
        bSliceIndex: 5, expectedHazard: true
    ),
    HazardCase(
        name: "degenerate ctts but only P/I slices → no hazard",
        ctts: .entries([(count: 32, offset: 0), (count: 32, offset: 1)]),
        bSliceIndex: nil, expectedHazard: false
    ),
    // Offsets swing 0/2000/4000 (well past the 500-tick half-duration threshold) inside every
    // window — a normal encoder's real per-frame reorder offsets — so it never reads degenerate.
    HazardCase(
        name: "healthy varied ctts + a B slice → no hazard",
        ctts: .entries((0..<64).map { (count: UInt32(1), offset: Int32([0, 2000, 4000][$0 % 3])) }),
        bSliceIndex: 5, expectedHazard: false
    ),
]

/// One "the ctts box's declared entry count can't be trusted" case: the box either promises
/// entries it doesn't physically carry, or promises far more than its own declared size could
/// ever hold.
struct MalformedCttsCase: Sendable, CustomTestStringConvertible {
    let name: String
    let raw: Data
    var testDescription: String { name }
}

private let malformedCttsCases: [MalformedCttsCase] = [
    MalformedCttsCase(name: "declares entries the box doesn't carry", raw: {
        var data = Data([0, 0, 0, 0]) // version/flags
        var declaredCount = UInt32(5).bigEndian
        withUnsafeBytes(of: &declaredCount) { data.append(contentsOf: $0) } // promises 5 entries…
        return data // …but no entry bytes follow.
    }()),
    MalformedCttsCase(name: "declares ~4 billion entries in a 16-byte box", raw: {
        var data = Data([0, 0, 0, 0]) // version/flags
        var declaredCount = UInt32.max.bigEndian
        withUnsafeBytes(of: &declaredCount) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 0]) // one real entry, 4 billion promised
        return data
    }()),
]

/// Box trees are assembled with `ISOBMFFFixtures` (shared, so the builders exist once for the
/// whole target) and fed through `InMemoryRandomAccessReader`.
@Suite("MediaProbe")
struct MediaProbeTests {
    private typealias Fixture = ISOBMFFFixtures

    private func probe(_ data: Data) async throws -> MediaProbeResult {
        try await MediaProbe.probe(InMemoryRandomAccessReader(data: data))
    }

    // MARK: - MP4 happy paths

    @Test("a well-formed avc1 + mp4a MP4 probes as complete with both codecs known")
    func completeMp4H264AacIsCompleteAndKnown() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
            Fixture.trak(stsdEntries: ["mp4a"], handler: "soun"),
        ]))
        #expect(result.container == .mp4)
        #expect(result.videoCodec == .known(.h264))
        #expect(result.audioCodec == .known(.aac))
        #expect(result.isComplete)
    }

    /// A non-faststart file puts `moov` after `mdat`; the walk must keep going rather than
    /// giving up at the first big box.
    @Test("a trailing moov is still found")
    func moovAfterMdatIsFoundAndComplete() async throws {
        let result = try await probe(Fixture.mp4(
            traks: [
                Fixture.trak(stsdEntries: ["hvc1"], handler: "vide"),
                Fixture.trak(stsdEntries: ["ec-3"], handler: "soun"),
            ],
            mdatByteCount: 512, moovAfterMdat: true
        ))
        #expect(result.videoCodec == .known(.hevc))
        #expect(result.audioCodec == .known(.eac3))
        #expect(result.isComplete)
    }

    @Test("every mapped video fourcc resolves to its codec", arguments: [
        ("avc1", VideoCodec.h264), ("avc3", .h264),
        ("hvc1", .hevc), ("hev1", .hevc), ("dvh1", .hevc), ("dvhe", .hevc),
        ("av01", .av1), ("vp09", .vp9),
    ])
    func videoFourccMapping(fourcc: String, expected: VideoCodec) async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: [fourcc], handler: "vide"),
        ]))
        #expect(result.videoCodec == .known(expected))
    }

    @Test("every mapped audio fourcc resolves to its codec", arguments: [
        ("mp4a", AudioCodec.aac), ("ac-3", .ac3), ("ec-3", .eac3), ("fLaC", .flac),
        ("Opus", .opus), ("dtsc", .dts), ("dtsh", .dts), ("dtsl", .dts), ("dtse", .dts),
        ("mlpa", .trueHD),
    ])
    func audioFourccMapping(fourcc: String, expected: AudioCodec) async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: [fourcc], handler: "soun"),
        ]))
        #expect(result.audioCodec == .known(expected))
    }

    /// An unmapped fourcc must read as `.unknown`, not `.none`: the selector routes unknown to
    /// VLC, whereas "no video at all" would let it assume AVKit can cope.
    @Test("an unmapped video fourcc reports unknown, not none")
    func unknownVideoFourccReportsUnknown() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["mp4v"], handler: "vide"),
        ]))
        #expect(result.videoCodec == .unknown)
    }

    /// With several audio tracks the LEAST supported one wins, so the whole file routes to the
    /// engine that can keep every track.
    @Test("the worst-case audio codec wins across tracks")
    func worstCaseAudioWinsForMultiTrack() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
            Fixture.trak(stsdEntries: ["mp4a"], handler: "soun"),
            Fixture.trak(stsdEntries: ["dtsc"], handler: "soun"),
        ]))
        #expect(result.audioCodec == .known(.dts))
    }

    /// Silently dropping an unrecognized track and picking a worst case among the rest would
    /// hide a track the selector can't reason about.
    @Test("an unrecognized audio fourcc alongside a known one still reports unknown")
    func unrecognizedAudioFourccAmongKnownOnesIsUnknown() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["mp4a", "zzzz"], handler: "soun"),
        ]))
        #expect(result.audioCodec == .unknown)
    }

    @Test("an audio trak with no sample entries reports unknown rather than none")
    func emptyAudioStsdIsUnknown() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: [], handler: "soun"),
        ]))
        #expect(result.audioCodec == .unknown)
    }

    @Test("a file with no audio trak at all reports none, not unknown")
    func noAudioTrakIsNone() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
        ]))
        #expect(result.audioCodec == .none)
        #expect(result.videoCodec == .known(.h264))
    }

    /// Only the FIRST video trak counts: a file with a cover-art or alternate video track must
    /// not have its main codec overwritten by the second one.
    @Test("a second video trak does not overwrite the first")
    func firstVideoTrakWins() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
            Fixture.trak(stsdEntries: ["mp4v"], handler: "vide"),
        ]))
        #expect(result.videoCodec == .known(.h264))
    }

    /// Subtitle/timed-metadata traks are neither video nor audio; they must be skipped rather
    /// than mistaken for either.
    @Test("a trak with an unrecognized handler is skipped")
    func unknownHandlerIsSkipped() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["tx3g"], handler: "subt"),
            Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
        ]))
        #expect(result.videoCodec == .known(.h264))
        #expect(result.audioCodec == .none)
    }

    @Test("a trak with no mdia box contributes nothing")
    func trakWithoutMdiaIsSkipped() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.box("trak", Fixture.box("tkhd", Data(count: 16))),
        ]))
        #expect(result.videoCodec == .none)
        #expect(result.audioCodec == .none)
    }

    // MARK: - Completeness

    /// A box declaring more bytes than the file holds is the still-downloading signal.
    @Test("an mdat overrunning EOF marks the file incomplete")
    func truncatedMdatIsIncomplete() async throws {
        var file = Fixture.ftyp() + Fixture.box("moov", Fixture.trak(stsdEntries: ["avc1"], handler: "vide"))
        var size = UInt32(1_048_576).bigEndian      // declares 1 MiB…
        withUnsafeBytes(of: &size) { file.append(contentsOf: $0) }
        file.append(Data("mdat".utf8))
        file.append(Data(count: 16))                 // …but only 16 bytes are here

        let result = try await probe(file)
        #expect(result.isComplete == false)
    }

    @Test("reaching EOF without a moov marks the file incomplete")
    func missingMoovIsIncomplete() async throws {
        let file = Fixture.ftyp() + Fixture.box("mdat", Data(count: 64))
        let result = try await probe(file)
        #expect(result.isComplete == false)
        #expect(result.container == .mp4, "the container is still known from the ftyp brand")
    }

    /// `size == 0` means "extends to end of file" — legal for the last top-level box, and the
    /// walk must terminate on it rather than looping.
    @Test("a size-0 final box is read as extending to EOF")
    func sizeZeroBoxExtendsToEOF() async throws {
        let file = Fixture.ftyp()
            + Fixture.box("moov", Fixture.trak(stsdEntries: ["avc1"], handler: "vide"))
            + Fixture.extendsToEOFBox("mdat", Data(count: 64))
        let result = try await probe(file)
        #expect(result.isComplete)
        #expect(result.videoCodec == .known(.h264))
    }

    /// A declared size shorter than the header itself is malformed; the conservative read is
    /// "not yet fully written" rather than "corrupt".
    @Test("a box declaring less than its own header marks the file incomplete")
    func undersizedBoxHeaderIsIncomplete() async throws {
        var file = Fixture.ftyp()
        var size = UInt32(4).bigEndian               // smaller than the 8-byte header
        withUnsafeBytes(of: &size) { file.append(contentsOf: $0) }
        file.append(Data("moov".utf8))

        let result = try await probe(file)
        #expect(result.isComplete == false)
    }

    @Test("a trailing partial header at EOF marks the file incomplete")
    func partialTrailingHeaderIsIncomplete() async throws {
        let file = Fixture.ftyp()
            + Fixture.box("moov", Fixture.trak(stsdEntries: ["avc1"], handler: "vide"))
            + Data(count: 5)                          // fewer than the 8 header bytes
        let result = try await probe(file)
        #expect(result.isComplete == false)
    }

    // MARK: - Malformed input hardening

    /// `offset + boxSize` would trap on a plain Int addition — the malformed trak must simply
    /// never be recognized.
    @Test("a nested box with a near-Int.max largesize degrades instead of trapping")
    func nestedBoxWithHugeLargesizeDoesNotCrashAndDegrades() async throws {
        let malformed = Fixture.rawBoxHeader(type: "trak", size32: 1, largesize: UInt64(Int.max) - 4)
        let result = try await probe(Fixture.ftyp() + Fixture.box("moov", malformed)
                                     + Fixture.box("mdat", Data(count: 8)))
        #expect(result.videoCodec == .none)
        #expect(result.audioCodec == .none)
    }

    @Test("the size == 1 largesize encoding is honoured on nested boxes too")
    func largesizeEncodedNestedBoxParsesCorrectly() async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trakLargesize(stsdEntries: ["avc1"], handler: "vide"),
        ]))
        #expect(result.videoCodec == .known(.h264))
    }

    /// Past the 64 MiB cap the codecs degrade to `.unknown` (→ VLC) rather than pulling an
    /// unbounded read over the LAN.
    @Test("a moov past the byte cap degrades to unknown instead of being read")
    func oversizedMoovDegradesToUnknown() async throws {
        let capBytes: UInt64 = 64 * 1024 * 1024
        var header = Fixture.ftyp()
        var size32 = UInt32(1).bigEndian
        withUnsafeBytes(of: &size32) { header.append(contentsOf: $0) }
        header.append(Data("moov".utf8))
        let moovSize = capBytes + 1024
        var large = moovSize.bigEndian
        withUnsafeBytes(of: &large) { header.append(contentsOf: $0) }

        let reader = SyntheticRandomAccessReader(
            prefix: header, declaredSize: UInt64(header.count) - 16 + moovSize
        )
        let result = try await MediaProbe.probe(reader)
        #expect(result.videoCodec == .unknown)
        #expect(result.audioCodec == .unknown)
        #expect(result.container == .mp4)
    }

    /// A short read where a full `moov` was expected must degrade, not misparse: over SMB a
    /// truncated read is an expected input, not a bug.
    @Test("a short read of the moov payload degrades to unknown")
    func shortMoovReadDegradesToUnknown() async throws {
        let file = Fixture.mp4(traks: [Fixture.trak(stsdEntries: ["avc1"], handler: "vide")])
        let reader = SyntheticRandomAccessReader(
            prefix: file, declaredSize: UInt64(file.count), maxBytesPerRead: 12
        )
        let result = try await MediaProbe.probe(reader)
        #expect(result.videoCodec == .unknown)
        #expect(result.audioCodec == .unknown)
    }

    // MARK: - Container sniffing

    @Test("EBML magic sniffs as mkv")
    func ebmlMagicIsMkv() async throws {
        let result = try await probe(Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(count: 64))
        #expect(result.container == .mkv)
        #expect(result.isComplete, "non-MP4 containers are never this probe's truncation signal")
    }

    @Test("RIFF/AVI magic sniffs as avi")
    func riffAviMagicIsAvi() async throws {
        var data = Data("RIFF".utf8)
        data.append(Data(count: 4))                  // RIFF chunk size, unread by the sniff
        data.append(Data("AVI ".utf8))
        data.append(Data(count: 64))
        let result = try await probe(data)
        #expect(result.container == .avi)
        #expect(result.isComplete)
    }

    @Test("0x47 sync bytes at 188-byte strides sniff as MPEG-TS")
    func tsSyncBytesMagicIsTs() async throws {
        var data = Data(count: 377)
        data[data.startIndex] = 0x47
        data[data.startIndex + 188] = 0x47
        data[data.startIndex + 376] = 0x47
        let result = try await probe(data)
        #expect(result.container == .ts)
        #expect(result.isComplete)
    }

    /// One missing sync byte disqualifies the stride test — otherwise any file with a stray
    /// 0x47 first byte would be routed as transport stream.
    @Test("a broken sync-byte stride is not MPEG-TS")
    func brokenSyncStrideIsNotTs() async throws {
        var data = Data(count: 377)
        data[data.startIndex] = 0x47
        data[data.startIndex + 376] = 0x47           // the 188-stride byte is missing
        let result = try await probe(data)
        #expect(result.container == nil)
    }

    @Test("a file too short for the TS stride test falls through to no container")
    func tooShortForTsStride() async throws {
        var data = Data(count: 200)
        data[data.startIndex] = 0x47
        let result = try await probe(data)
        #expect(result.container == nil)
    }

    @Test("the 'qt  ' brand sniffs as mov rather than mp4")
    func qtBrandIsMov() async throws {
        let result = try await probe(Fixture.mp4(
            brand: "qt  ", traks: [Fixture.trak(stsdEntries: ["avc1"], handler: "vide")]
        ))
        #expect(result.container == .mov)
    }

    @Test("unrecognized leading bytes yield no container")
    func unknownMagicIsNilContainer() async throws {
        let result = try await probe(Data(count: 64))
        #expect(result.container == nil)
        #expect(result.videoCodec == .none)
        #expect(result.isComplete)
    }

    @Test("an empty file yields no container and no codecs")
    func emptyFile() async throws {
        let result = try await probe(Data())
        #expect(result.container == nil)
        #expect(result.videoCodec == .none)
        #expect(result.audioCodec == .none)
    }

    // MARK: - Decode-order timestamp hazard

    @Test("decode-order timestamp hazard, per ctts shape and B-slice presence", arguments: hazardCases)
    func decodeOrderTimestampHazard(_ row: HazardCase) async throws {
        let sampleCount = 64
        let samples = (0..<sampleCount).map { index in
            Fixture.h264Sample(nalLengthSize: 4, sliceType: index == row.bSliceIndex ? 1 : 2)
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: row.ctts,
            sampleData: samples
        )

        let result = try await probe(data)
        #expect(result.videoCodec == .known(.h264))
        #expect(result.avPlayerHazards.contains(.decodeOrderTimestamps) == row.expectedHazard)
    }

    /// A `ctts` box whose declared entry count can't be trusted — either it promises entries it
    /// doesn't carry, or it promises far more than the 16-byte box could ever hold — is a
    /// different signal than "no ctts at all": it must fail open rather than being read as an
    /// automatic hazard candidate or driving a giant allocation, and the rest of the probe
    /// result stays intact.
    @Test("an untrustworthy ctts entry count fails open — no hazard, other fields intact", arguments: malformedCttsCases)
    func malformedCttsFailsOpen(_ row: MalformedCttsCase) async throws {
        let sampleCount = 8
        let samples = (0..<sampleCount).map { index in
            Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 2 ? 1 : 2)
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: .raw(row.raw),
            sampleData: samples
        )

        let result = try await probe(data)
        #expect(result.container == .mp4)
        #expect(result.videoCodec == .known(.h264))
        #expect(result.avPlayerHazards.isEmpty)
    }

    /// The sample table is fully valid and degenerate, but the sample bytes themselves aren't
    /// reachable (the file ends right where `mdat`'s payload would start) — the B-slice read
    /// comes back empty, and that must fail open too, not crash or misreport.
    @Test("unreadable sample bytes fail open — no hazard, other fields intact")
    func unreadableSampleBytesFailsOpen() async throws {
        let sampleCount = 64
        let samples = (0..<sampleCount).map { index in
            Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 5 ? 1 : 2)
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: .entries([(count: 32, offset: 0), (count: 32, offset: 1)]),
            sampleData: samples
        )
        let sampleBytesTotal = samples.reduce(0) { $0 + $1.count }
        let reader = SyntheticRandomAccessReader(prefix: data, declaredSize: UInt64(data.count - sampleBytesTotal))

        let result = try await MediaProbe.probe(reader)
        #expect(result.container == .mp4)
        #expect(result.videoCodec == .known(.h264))
        #expect(result.avPlayerHazards.isEmpty)
    }

    /// 32 samples of 20 KiB each sum well past `confirmBSlices`' 256 KiB read budget in one
    /// contiguous span. The old coalesced-bulk-read path would have spent the whole budget
    /// reading sample 0 alone and never reached sample 5's B slice; the per-sample-head fallback
    /// must still find it.
    @Test("a hazard whose samples sum past the read budget is still found via per-sample reads")
    func hazardBeyondReadBudgetStillDetected() async throws {
        let sampleCount = 32
        let samples = (0..<sampleCount).map { index -> Data in
            var sample = Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 5 ? 1 : 2)
            // Pad well past the NAL bytes — the B slice's own NAL stays in the first few bytes,
            // which the 4 KiB per-sample head read still covers, but 32 of these coalesced into
            // one bulk read would blow the budget on sample 0 alone.
            sample.append(Data(count: 20_000 - sample.count))
            return sample
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: .absent,
            sampleData: samples
        )

        let result = try await probe(data)
        #expect(result.avPlayerHazards.contains(.decodeOrderTimestamps))
    }

    /// The fixed-size `stsz` branch (`sample_size != 0`, no per-sample table) reaching the
    /// hazard detector end-to-end — every other fixture in this suite goes through the
    /// per-sample table branch instead.
    @Test("a hazard behind a fixed-size stsz table is still detected")
    func hazardWithFixedSizeStszIsDetected() async throws {
        let sampleCount = 64
        let samples = (0..<sampleCount).map { index in
            Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 5 ? 1 : 2)
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: .absent,
            sampleData: samples,
            stszEncoding: .fixed
        )

        let result = try await probe(data)
        #expect(result.avPlayerHazards.contains(.decodeOrderTimestamps))
    }

    /// Baseline profile (profile_idc 66) H.264 cannot carry B-slices, so the probe must skip the
    /// sample-read scan entirely — even with a degenerate (absent) ctts and a (synthetically
    /// implausible, but proving the skip) planted B slice, no hazard is reported.
    @Test("a Baseline-profile stream reports no decode-order hazard even with a planted B slice")
    func baselineProfileSkipsDecodeOrderScan() async throws {
        let sampleCount = 64
        let samples = (0..<sampleCount).map { index in
            Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 5 ? 1 : 2)
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: .absent,
            sampleData: samples,
            spsNALs: [Fixture.h264SPS(profileIdc: 66, frameMbsOnlyFlag: 1)]
        )

        let result = try await probe(data)
        #expect(!result.avPlayerHazards.contains(.decodeOrderTimestamps))
    }

    /// Two stsc/stco chunks of 16 samples each, with the B slice in chunk 2 (sample index 20) —
    /// a single-chunk fixture can't exercise `sampleByteRanges` walking past its first `stco`
    /// entry, so this locks that chunk walk.
    @Test("a hazard reached only by walking into a second stsc/stco chunk is still detected")
    func hazardAcrossMultipleChunksIsDetected() async throws {
        let sampleCount = 32
        let samples = (0..<sampleCount).map { index in
            Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 20 ? 1 : 2)
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: .absent,
            sampleData: samples,
            samplesPerChunk: 16
        )

        let result = try await probe(data)
        #expect(result.avPlayerHazards.contains(.decodeOrderTimestamps))
    }

    // MARK: - In-band parameter sets

    @Test("in-band-parameter-set sample entry tags are hazarded, out-of-band tags are not", arguments: [
        ("hev1", true), ("avc3", true), ("avc4", true), ("dvhe", true),
        ("hvc1", false), ("avc1", false), ("dvh1", false),
    ])
    func inBandParameterSetsHazard(fourcc: String, expectedHazard: Bool) async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: [fourcc], handler: "vide"),
        ]))
        #expect(result.avPlayerHazards.contains(.inBandParameterSets) == expectedHazard)
    }

    // MARK: - Interlaced (field-coded) video

    @Test("an avc1 SPS's frame_mbs_only_flag drives the interlace hazard", arguments: [
        (66, 1, false),   // baseline, progressive
        (66, 0, true),    // baseline, field-coded
        (100, 1, false),  // High profile (exercises the chroma/bit-depth branch), progressive
        (100, 0, true),   // High profile, field-coded
    ])
    func interlacedH264Hazard(profileIdc: Int, frameMbsOnlyFlag: Int, expectedHazard: Bool) async throws {
        let sps = Fixture.h264SPS(profileIdc: profileIdc, frameMbsOnlyFlag: frameMbsOnlyFlag)
        let entry = Fixture.avcVideoSampleEntry(spsNALs: [sps])
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trakRaw(stsdEntries: [entry], handler: "vide"),
        ]))
        #expect(result.avPlayerHazards.contains(.interlacedVideo) == expectedHazard)
    }

    /// The scaling-matrix branch is a deliberate parser bail, not a confirmed-progressive read —
    /// it must report no hazard even though the field-coded flag it never reaches would be 0.
    @Test("a High-profile SPS with seq_scaling_matrix_present_flag set fails open")
    func scalingMatrixPresentFailsOpen() async throws {
        let sps = Fixture.h264SPS(profileIdc: 100, frameMbsOnlyFlag: 0, scalingMatrixPresent: true)
        let entry = Fixture.avcVideoSampleEntry(spsNALs: [sps])
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trakRaw(stsdEntries: [entry], handler: "vide"),
        ]))
        #expect(!result.avPlayerHazards.contains(.interlacedVideo))
    }

    @Test("a truncated SPS fails open rather than misreading garbage bits")
    func truncatedSPSFailsOpen() async throws {
        let sps = Fixture.h264SPS(profileIdc: 66, frameMbsOnlyFlag: 0, truncated: true)
        let entry = Fixture.avcVideoSampleEntry(spsNALs: [sps])
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trakRaw(stsdEntries: [entry], handler: "vide"),
        ]))
        #expect(!result.avPlayerHazards.contains(.interlacedVideo))
    }

    @Test("hvcC's interlaced/progressive source flags drive the HEVC interlace hazard", arguments: [
        (UInt8(0x40), true),   // interlaced only
        (UInt8(0x80), false),  // progressive only
        (UInt8(0xC0), false),  // both set — not treated as interlaced
        (UInt8(0x00), false),  // neither set
    ])
    func interlacedHevcHazard(constraintByte6: UInt8, expectedHazard: Bool) async throws {
        let entry = Fixture.hevcVideoSampleEntry(type: "hvc1", constraintByte6: constraintByte6)
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trakRaw(stsdEntries: [entry], handler: "vide"),
        ]))
        #expect(result.avPlayerHazards.contains(.interlacedVideo) == expectedHazard)
    }

    // MARK: - Multiple sample descriptions

    @Test("stsd entry count on the video trak drives multipleSampleDescriptions", arguments: [
        (["avc1", "hvc1"], true),
        (["avc1"], false),
    ])
    func multipleSampleDescriptionsHazard(stsdEntries: [String], expectedHazard: Bool) async throws {
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: stsdEntries, handler: "vide"),
        ]))
        #expect(result.avPlayerHazards.contains(.multipleSampleDescriptions) == expectedHazard)
    }

    /// A `free`/`skip` padding box (or any stray bytes) trailing the stsd's DECLARED entries must
    /// not be miscounted as a second sample description — the walk has to stop at `entry_count`,
    /// not at the box's own end.
    @Test("a padding box trailing one declared stsd entry is not read as a second one")
    func stsdTrailingPaddingBoxIsNotMultipleSampleDescriptions() async throws {
        var hdlr = Data(count: 8)
        hdlr.append(Data("vide".utf8))
        hdlr.append(Data(count: 13))

        var stsdPayload = Data([0, 0, 0, 0])
        var entryCount = UInt32(1).bigEndian
        withUnsafeBytes(of: &entryCount) { stsdPayload.append(contentsOf: $0) }
        stsdPayload.append(Fixture.box("avc1"))
        stsdPayload.append(Fixture.box("free")) // trailing padding, not a real second entry
        let stsd = Fixture.box("stsd", stsdPayload)

        let trakContent = Fixture.box("mdia", Fixture.box("hdlr", hdlr) + Fixture.box("minf", Fixture.box("stbl", stsd)))
        let trak = Fixture.box("trak", trakContent)

        let result = try await probe(Fixture.mp4(traks: [trak]))
        #expect(!result.avPlayerHazards.contains(.multipleSampleDescriptions))
        #expect(result.videoCodec == .known(.h264))
    }

    // MARK: - Missing parameter sets

    @Test("avcC's SPS count drives missingParameterSets", arguments: [
        ([], true),
        ([ISOBMFFFixtures.h264SPS(profileIdc: 66, frameMbsOnlyFlag: 1)], false),
    ])
    func missingParameterSetsHazard(spsNALs: [Data], expectedHazard: Bool) async throws {
        let entry = Fixture.avcVideoSampleEntry(spsNALs: spsNALs)
        let result = try await probe(Fixture.mp4(traks: [
            Fixture.trakRaw(stsdEntries: [entry], handler: "vide"),
        ]))
        #expect(result.avPlayerHazards.contains(.missingParameterSets) == expectedHazard)
    }

    // MARK: - Combined hazards

    /// A file can carry more than one hazard at once: an avc1 stream that's both field-coded and
    /// exhibits the decode-order-timestamp defect must report both, independently.
    @Test("an interlaced avc1 stream with a degenerate ctts and a B slice reports both hazards")
    func combinedInterlacedAndDecodeOrderHazards() async throws {
        let sampleCount = 64
        let samples = (0..<sampleCount).map { index in
            Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 5 ? 1 : 2)
        }
        let data = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(sampleCount), delta: 1000)],
            ctts: .absent,
            sampleData: samples,
            // Main profile (77), not Baseline (66) — Baseline can never carry a B-slice, so the
            // decode-order-hazard scan would skip before this hazard could combine with interlace.
            spsNALs: [Fixture.h264SPS(profileIdc: 77, frameMbsOnlyFlag: 0)]
        )

        let result = try await probe(data)
        #expect(result.avPlayerHazards.contains(.interlacedVideo))
        #expect(result.avPlayerHazards.contains(.decodeOrderTimestamps))
    }
}

@Suite("ProbedCodec")
struct ProbedCodecTests {
    /// `.none` ("the container carries no such stream") and `.unknown` ("it does, but we can't
    /// name the codec") must stay distinguishable — the selector routes them differently.
    @Test("knownValue unwraps only the known case")
    func knownValue() {
        #expect(ProbedCodec.known(VideoCodec.h264).knownValue == .h264)
        #expect(ProbedCodec<VideoCodec>.unknown.knownValue == nil)
        #expect(ProbedCodec<VideoCodec>.none.knownValue == nil)
    }

    @Test("unknown and none are not the same value")
    func unknownIsNotNone() {
        #expect(ProbedCodec<AudioCodec>.unknown != ProbedCodec<AudioCodec>.none)
    }
}

@Suite("InMemoryRandomAccessReader")
struct InMemoryRandomAccessReaderTests {
    private let reader = InMemoryRandomAccessReader(data: Data([0, 1, 2, 3, 4, 5, 6, 7]))

    @Test("reports the backing byte count as the file size")
    func fileSize() async throws {
        let size = try await reader.fileSize
        #expect(size == 8)
    }

    /// A read overrunning EOF returns the available PREFIX rather than throwing, mirroring POSIX
    /// pread — the box walk relies on a short read to detect truncation.
    @Test("a read overrunning EOF returns the available prefix")
    func readPastEOFReturnsPrefix() async throws {
        let data = try await reader.read(offset: 6, length: 8)
        #expect(Array(data) == [6, 7])
    }

    @Test("a read starting past EOF, or of no length, is empty", arguments: [
        (UInt64(8), 4), (UInt64(100), 4), (UInt64(0), 0),
    ])
    func emptyReads(offset: UInt64, length: Int) async throws {
        let data = try await reader.read(offset: offset, length: length)
        #expect(data.isEmpty)
    }
}

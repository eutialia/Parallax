import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

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

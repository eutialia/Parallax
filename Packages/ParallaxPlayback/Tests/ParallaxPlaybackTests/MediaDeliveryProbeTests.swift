import Foundation
import Synchronization
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport

/// Where a delivery sends a file from what its first reads show: served as it is, handed to the
/// bridge, or refused before either. The MP4 box trees built here hold no samples the bridge
/// can read, so each one handed to it comes back refused by the bridge.
@Suite("MediaDelivery — what the probe decides", .timeLimit(.minutes(1)))
struct MediaDeliveryProbeTests {
    typealias Fixture = ISOBMFFFixtures

    /// What the app sees once `start` returns or throws.
    enum Route: Equatable, CustomStringConvertible {
        /// The URL serves the file's own bytes, with this content type.
        case served(String)
        /// The URL serves a master playlist.
        case bridged
        case refusedByTheBridge
        case unplayable(Unplayable)

        var description: String {
            switch self {
            case .served(let type): "served as \(type)"
            case .bridged: "bridged"
            case .refusedByTheBridge: "refused by the bridge"
            case .unplayable(let reason): "unplayable: \(reason)"
            }
        }
    }

    static func route(of reader: any RandomAccessReading, support: AVPlayerSupport = .baseline) async throws -> Route {
        let delivery: MediaDelivery
        do {
            delivery = try await MediaDelivery.start(
                reading: reader, fileName: "clip.mp4", support: support, clock: TestClock())
        } catch Unplayable.refused {
            return .refusedByTheBridge
        } catch let reason as Unplayable {
            return .unplayable(reason)
        }
        let body: Data, response: URLResponse
        do {
            (body, response) = try await ephemeralHTTPSession().data(from: delivery.url)
        } catch {
            await delivery.stop()
            throw error
        }
        await delivery.stop()
        if body.starts(with: Data("#EXTM3U".utf8)) { return .bridged }
        let file = try await reader.read(offset: 0, length: Int(try await reader.fileSize))
        #expect(body == file, "a file served as it is is served whole")
        return .served((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    static func route(of bytes: Data, support: AVPlayerSupport = .baseline) async throws -> Route {
        try await route(of: InMemoryRandomAccessReader(data: bytes), support: support)
    }

    /// A device whose AVPlayer opens MP4, MOV and HLS and decodes `video` and `audio`.
    static func decoding(
        video: Set<VideoCodec> = Set(VideoCodec.allCases), audio: Set<AudioCodec> = Set(AudioCodec.allCases)
    ) -> AVPlayerSupport {
        AVPlayerSupport(containers: [.mp4, .mov, .hls], videoCodecs: video, audioCodecs: audio)
    }

    static func fixture(_ file: String) throws -> Data { try BridgeFixture.data(file) }

    static func subtitledMP4() throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: "subtitled", withExtension: "mp4", subdirectory: "Fixtures")))
    }

    static func patched(_ data: Data, at offset: Int, to byte: UInt8) -> Data {
        var patched = data
        patched[patched.startIndex + offset] = byte
        return patched
    }

    // MARK: - Codecs

    @Test("an MP4 is served where the device decodes the video codec its sample entry names, and bridged where it does not",
          arguments: [("avc1", VideoCodec.h264), ("hvc1", .hevc), ("dvh1", .hevc), ("av01", .av1), ("vp09", .vp9)])
    func videoSampleEntryNamesItsCodec(fourcc: String, codec: VideoCodec) async throws {
        let file = Fixture.mp4(traks: [Fixture.trak(stsdEntries: [fourcc], handler: "vide")])

        #expect(try await Self.route(of: file, support: Self.decoding(video: [codec])) == .served("video/mp4"))
        #expect(try await Self.route(of: file, support: Self.decoding(video: Set(VideoCodec.allCases).subtracting([codec])))
            == .refusedByTheBridge)
    }

    /// AVPlayer takes parameter sets only from the sample entry's configuration record.
    @Test("an MP4 whose sample entry leaves its parameter sets to the samples is bridged on a device that decodes everything, and one whose entry holds them is served",
          arguments: [
            ("hev1", Route.refusedByTheBridge), ("avc3", .refusedByTheBridge), ("avc4", .refusedByTheBridge),
            ("dvhe", .refusedByTheBridge), ("hvc1", .served("video/mp4")), ("avc1", .served("video/mp4")),
            ("dvh1", .served("video/mp4")),
          ])
    func inBandParameterSetsAreBridged(fourcc: String, route: Route) async throws {
        let file = Fixture.mp4(traks: [Fixture.trak(stsdEntries: [fourcc], handler: "vide")])
        #expect(try await Self.route(of: file, support: BridgeFixture.everyDecoder) == route)
    }

    @Test("an MP4 whose video sample entry the probe does not know is bridged, not served as a file with no video")
    func unknownVideoSampleEntryIsBridged() async throws {
        let file = Fixture.mp4(traks: [Fixture.trak(stsdEntries: ["mp4v"], handler: "vide")])
        #expect(try await Self.route(of: file, support: BridgeFixture.everyDecoder) == .refusedByTheBridge)
    }

    @Test("an MP4 is served where the device decodes the audio codec its sample entry names, and bridged where it does not",
          arguments: [
            ("mp4a", AudioCodec.aac), ("ac-3", .ac3), ("ec-3", .eac3), ("fLaC", .flac), ("Opus", .opus),
            ("dtsc", .dts), ("dtsh", .dts), ("dtsl", .dts), ("dtse", .dts), ("mlpa", .trueHD),
          ])
    func audioSampleEntryNamesItsCodec(fourcc: String, codec: AudioCodec) async throws {
        try await Self.expectPlayed(as: codec, Fixture.mp4(traks: [Fixture.trak(stsdEntries: [fourcc], handler: "soun")]))
    }

    @Test("an mp4a entry plays as the codec its esds object type names, and is bridged on every device when the esds does not parse",
          arguments: [
            (mp4aEntry(objectType: 0x40), AudioCodec?.some(.aac)), (mp4aEntry(objectType: 0x67), .aac),
            (mp4aEntry(objectType: 0x40, url: "rtsp"), .aac), (mp4aEntry(objectType: 0x6B), .mp3),
            (mp4aEntry(objectType: 0xA9), .dts), (mp4aEntry(objectType: 0xA5), nil),
            (mp4aEntry(objectType: 0x40, descriptorTag: 0x05), nil),
          ])
    func mp4aNamedByObjectType(entry: Data, codec: AudioCodec?) async throws {
        let file = Fixture.mp4(traks: [Fixture.trakRaw(stsdEntries: [entry], handler: "soun")])
        if let codec {
            try await Self.expectPlayed(as: codec, file)
        } else {
            #expect(try await Self.route(of: file, support: BridgeFixture.everyDecoder) == .refusedByTheBridge)
        }
    }

    /// Served where the device decodes `codec` and no other audio, and bridged where it decodes
    /// every audio codec but `codec`.
    private static func expectPlayed(as codec: AudioCodec, _ file: Data) async throws {
        #expect(try await route(of: file, support: decoding(audio: [codec])) == .served("video/mp4"))
        #expect(try await route(of: file, support: decoding(audio: Set(AudioCodec.allCases).subtracting([codec])))
            == .refusedByTheBridge)
    }

    /// An `mp4a` sample entry of version 0 whose `esds` holds an ES descriptor, which may carry
    /// a URL, and its decoder configuration.
    private static func mp4aEntry(objectType: UInt8, url: String? = nil, descriptorTag: UInt8 = 0x03) -> Data {
        let urlField = url.map { Data([UInt8($0.utf8.count)] + $0.utf8) } ?? Data()
        let decoderConfiguration = Data([0x04, 13, objectType, 0x15] + Array(repeating: 0, count: 11))
        let descriptor = Data([0, 1, url == nil ? 0 : 0x40]) + urlField + decoderConfiguration
        let esds = Fixture.box("esds", Data([0, 0, 0, 0, descriptorTag, UInt8(descriptor.count)]) + descriptor)
        return Fixture.box("mp4a", Data(count: 28) + esds)
    }

    @Test("a second audio track the device cannot decode sends the file to the bridge")
    func everyAudioTrackCounts() async throws {
        let file = Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
            Fixture.trak(stsdEntries: ["mp4a"], handler: "soun"),
            Fixture.trak(stsdEntries: ["dtsc"], handler: "soun"),
        ])

        #expect(try await Self.route(of: file, support: Self.decoding(audio: [.aac, .dts])) == .served("video/mp4"))
        #expect(try await Self.route(of: file, support: Self.decoding(audio: Set(AudioCodec.allCases).subtracting([.dts])))
            == .refusedByTheBridge)
    }

    @Test("an audio trak the probe cannot name sends the file to the bridge on every device", arguments: [
        // An unrecognized entry alongside a known one, and a trak with no entries at all.
        ["mp4a", "zzzz"], [],
    ])
    func unnamedAudioIsBridged(entries: [String]) async throws {
        let file = Fixture.mp4(traks: [Fixture.trak(stsdEntries: entries, handler: "soun")])
        #expect(try await Self.route(of: file, support: BridgeFixture.everyDecoder) == .refusedByTheBridge)
    }

    @Test("a file with no audio trak is served on a device that decodes no audio")
    func fileWithoutAudioIsServed() async throws {
        let file = Fixture.mp4(traks: [Fixture.trak(stsdEntries: ["avc1"], handler: "vide")])
        #expect(try await Self.route(of: file, support: Self.decoding(audio: [])) == .served("video/mp4"))
    }

    @Test("a second video trak does not stand in for the first")
    func firstVideoTrakDecides() async throws {
        let file = Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
            Fixture.trak(stsdEntries: ["mp4v"], handler: "vide"),
        ])
        #expect(try await Self.route(of: file) == .served("video/mp4"))
    }

    @Test("a trak with an unrecognized handler is skipped", arguments: [
        (Fixture.mp4(traks: [
            Fixture.trak(stsdEntries: ["tx3g"], handler: "subt"), Fixture.trak(stsdEntries: ["avc1"], handler: "vide"),
        ]), decoding(audio: [])),
        // H.264, AAC, and two tx3g subtitle tracks under the `sbtl` handler.
        (try subtitledMP4(), .baseline),
    ])
    func unknownHandlerIsSkipped(file: Data, support: AVPlayerSupport) async throws {
        #expect(try await Self.route(of: file, support: support) == .served("video/mp4"))
    }

    @Test("a trak with no mdia box contributes nothing")
    func trakWithoutMdiaIsSkipped() async throws {
        let file = Fixture.mp4(traks: [Fixture.box("trak", Fixture.box("tkhd", Data(count: 16)))])
        let decodesNothing = AVPlayerSupport(containers: [.mp4], videoCodecs: [], audioCodecs: [])
        #expect(try await Self.route(of: file, support: decodesNothing) == .served("video/mp4"))
    }

    @Test("an MOV is refused on a device whose AVPlayer opens no QuickTime file")
    func movWithoutQuickTimeIsRefused() async throws {
        let file = Fixture.mp4(brand: "qt  ", traks: [Fixture.trak(stsdEntries: ["avc1"], handler: "vide")])
        let mp4Only = AVPlayerSupport(containers: [.mp4, .hls], videoCodecs: [.h264], audioCodecs: [.aac])
        #expect(try await Self.route(of: file, support: mp4Only) == .unplayable(.container(.mov)))
    }

    @Test("an MP4 in a profile the device decodes is served, and one in a profile it does not is bridged", arguments: [
        ("numbered-h264-high10.mp4", decoding(video: [.h264, .hevc]), Route.bridged),
        ("numbered-h264-high10.mp4", AVPlayerSupport(
            containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc], audioCodecs: [.aac], decodesH264High10: true),
         .served("video/mp4")),
        // AV1 Main, served only where there is an AV1 decoder.
        ("numbered-av1.mp4", decoding(video: [.h264, .hevc]), .bridged),
        ("numbered-av1.mp4", decoding(video: [.h264, .hevc, .av1]), .served("video/mp4")),
        // H.264 High 4:2:2, which no Apple decoder takes.
        ("numbered-h264-422.mp4", BridgeFixture.everyDecoder, .bridged),
    ])
    func profileFollowsTheDevice(file: String, support: AVPlayerSupport, route: Route) async throws {
        #expect(try await Self.route(of: Self.fixture(file), support: support) == route)
    }

    // MARK: - Completeness

    /// Files an encoder or a copy is still writing.
    static func filesBeingWritten() -> [Data] {
        let moov: Data = Fixture.box("moov", Fixture.trak(stsdEntries: ["avc1"], handler: "vide"))
        let overrunningMdat: Data = Data([0x00, 0x10, 0x00, 0x00]) + Data("mdat".utf8) + Data(count: 16)
        let undersizedHeader: Data = Data([0, 0, 0, 4]) + Data("free".utf8)
        return [
            // An mdat declaring 1 MiB with 16 bytes of it present.
            Fixture.ftyp() + moov + overrunningMdat,
            // No moov yet.
            Fixture.ftyp() + Fixture.box("mdat", Data(count: 64)),
            // A box declaring 4 bytes, fewer than its own header.
            Fixture.ftyp() + moov + undersizedHeader,
            // Five bytes of a header after the moov.
            Fixture.ftyp() + moov + Data(count: 5),
        ]
    }

    @Test("an MP4 still being written is refused as incomplete", arguments: filesBeingWritten())
    func fileBeingWrittenIsIncomplete(file: Data) async throws {
        #expect(try await Self.route(of: file) == .unplayable(.incompleteFile))
    }

    /// A box of size 0 runs to the end of the file, as a live recorder writes its last one.
    @Test("a size-0 final box is read as extending to EOF")
    func sizeZeroBoxExtendsToEOF() async throws {
        let file = Fixture.ftyp()
            + Fixture.box("moov", Fixture.trak(stsdEntries: ["avc1"], handler: "vide"))
            + Fixture.extendsToEOFBox("mdat", Data(repeating: 0xFF, count: 64))
        #expect(try await Self.route(of: file) == .served("video/mp4"))
    }

    // MARK: - Hostile headers

    @Test("a nested box with a near-Int.max largesize is skipped, not trapped on")
    func nestedHugeLargesizeIsSkipped() async throws {
        let malformed = Fixture.rawBoxHeader(type: "trak", size32: 1, largesize: UInt64(Int.max) - 4)
        let file = Fixture.ftyp() + Fixture.box("moov", malformed) + Fixture.box("mdat", Data(count: 8))
        #expect(try await Self.route(of: file) == .served("video/mp4"))
    }

    @Test("the size == 1 largesize encoding is honoured on nested boxes too")
    func nestedLargesizeIsRead() async throws {
        let file = Fixture.mp4(traks: [Fixture.trakLargesize(stsdEntries: ["avc1"], handler: "vide")])

        #expect(try await Self.route(of: file, support: Self.decoding(video: [.h264])) == .served("video/mp4"))
        #expect(try await Self.route(of: file, support: Self.decoding(video: [.hevc])) == .refusedByTheBridge)
    }

    /// A share file of `size` bytes: `prefix`, then zeros.
    private struct ZeroPaddedReader: RandomAccessReading {
        let prefix: Data
        let size: UInt64

        var fileSize: UInt64 { get async throws { size } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            guard offset < size, length > 0 else { return Data() }
            let start = Int(offset)
            let end = Int(min(offset + UInt64(length), size))
            let held = start < prefix.count ? prefix[(prefix.startIndex + start)..<(prefix.startIndex + min(end, prefix.count))] : Data()
            return Data(held) + Data(count: end - start - held.count)
        }
    }

    /// Past 64 MiB a moov is not read into memory, and its codecs are unknown.
    @Test("a moov past the 64 MiB cap is not read, and the file goes to the bridge")
    func moovPastTheCapGoesToTheBridge() async throws {
        let moovSize = UInt64(64 << 20) + 1024
        var header = Fixture.ftyp() + Data([0, 0, 0, 1]) + Data("moov".utf8)
        withUnsafeBytes(of: moovSize.bigEndian) { header.append(contentsOf: $0) }
        let reader = ZeroPaddedReader(prefix: header, size: UInt64(header.count) - 16 + moovSize)

        #expect(try await Self.route(of: reader) == .refusedByTheBridge)
    }

    // MARK: - Containers

    @Test("bytes that start no container the probe knows are refused as an unknown container", arguments: [
        ("64 zero bytes", Data(count: 64)),
        ("an empty file", Data()),
        ("an ASF whose header GUID is one byte off", patched(try fixture("asf-h264.asf"), at: 15, to: 0x6D)),
        ("an M2TS whose third sync byte is gone", patched(try fixture("m2ts-h264.m2ts"), at: 4 + 2 * 192, to: 0)),
        ("a TS whose second sync byte is gone", patched(try fixture("ts-h264.ts"), at: 188, to: 0)),
        ("a TS too short to hold a third packet", try fixture("ts-h264.ts").prefix(200)),
        ("an MPEG start code that is not a pack header", patched(try fixture("numbered-mpeg2.mpg"), at: 3, to: 0xB3)),
    ])
    func unknownContainerIsRefused(input: String, file: Data) async throws {
        #expect(try await Self.route(of: file) == .unplayable(.container(nil)), "\(input)")
    }

    // MARK: - Decode-order show times

    /// One file of 64 H.264 samples a second apart: a ctts shape, the sample that is a B slice,
    /// and the sample entry's tag.
    struct DecodeOrderCase: Sendable, CustomTestStringConvertible {
        let name: String
        let ctts: ISOBMFFFixtures.CttsFixture
        let bSliceIndex: Int?
        var tag = "avc1"
        let hazard: Bool
        var testDescription: String { name }
    }

    @Test("an H.264 MP4 whose B-pictures would show in decode order fails with that hazard, and one with real show times is served",
          arguments: [
            DecodeOrderCase(
                name: "piecewise-constant ctts and a B slice",
                ctts: .entries([(count: 32, offset: 0), (count: 32, offset: 1)]), bSliceIndex: 5, hazard: true),
            // The offset climbs a tick every 4 samples: any 32-sample window spreads 8 ticks,
            // far under half a frame.
            DecodeOrderCase(
                name: "slowly drifting ctts and a B slice",
                ctts: .entries((0..<16).map { (count: UInt32(4), offset: Int32($0)) }), bSliceIndex: 5, hazard: true),
            DecodeOrderCase(name: "no ctts and a B slice", ctts: .absent, bSliceIndex: 5, hazard: true),
            // The bridge carries this hazard too, so the in-band parameter sets change nothing.
            DecodeOrderCase(name: "no ctts and a B slice, under avc3", ctts: .absent, bSliceIndex: 5, tag: "avc3", hazard: true),
            DecodeOrderCase(
                name: "degenerate ctts and only P slices",
                ctts: .entries([(count: 32, offset: 0), (count: 32, offset: 1)]), bSliceIndex: nil, hazard: false),
            // Offsets of 0, 2000 and 4000 in every window, as an encoder reorders frames.
            DecodeOrderCase(
                name: "varied ctts and a B slice",
                ctts: .entries((0..<64).map { (count: UInt32(1), offset: Int32([0, 2000, 4000][$0 % 3])) }),
                bSliceIndex: 5, hazard: false),
          ])
    func decodeOrderShowTimes(_ row: DecodeOrderCase) async throws {
        let samples = (0..<64).map { Fixture.h264Sample(nalLengthSize: 4, sliceType: $0 == row.bSliceIndex ? 1 : 2) }
        let file = Fixture.h264HazardMp4(sttsEntries: [(count: 64, delta: 1000)], ctts: row.ctts, sampleData: samples)
            .replacing(Data("avc1".utf8), with: Data(row.tag.utf8))

        let route = try await Self.route(of: file)
        let expected = row.hazard ? Route.unplayable(.directHazards([.decodeOrderTimestamps])) : row.tag == "avc1"
            ? .served("video/mp4") : .refusedByTheBridge
        #expect(route == expected)
    }

    /// A fragmented MP4's moov holds no samples: each fragment's `trun` times its own.
    @Test("a fragmented MP4 whose show times follow decode order fails with that hazard, as an unfragmented one does",
          arguments: [
            ("numbered-h264-fragmented-no-show-times.mp4", Route.unplayable(.directHazards([.decodeOrderTimestamps]))),
            // Its fragments' data counted from an explicit base offset, not from the moof.
            ("numbered-h264-fragmented-base-offset-no-show-times.mp4", .unplayable(.directHazards([.decodeOrderTimestamps]))),
            // Its samples' durations given only by the moov's `trex`.
            ("numbered-h264-fragmented-trex-durations-no-show-times.mp4", .unplayable(.directHazards([.decodeOrderTimestamps]))),
            ("numbered-h264-no-show-times.mp4", .unplayable(.directHazards([.decodeOrderTimestamps]))),
            ("numbered-h264-fragmented.mp4", .served("video/mp4")),
          ])
    func fragmentedDecodeOrderShowTimes(file: String, route: Route) async throws {
        #expect(try await Self.route(of: Self.fixture(file)) == route)
    }

    /// `file` with `padding` bytes of `free` box appended inside its first `moof`, the moof's
    /// size and its `trun` data offsets moved to match, so its samples still lie where it says.
    static func paddingFirstFragment(_ file: Data, by padding: Int) throws -> Data {
        func uint32(_ data: Data, _ at: Int) -> Int {
            data[data.startIndex + at..<data.startIndex + at + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        func boxes(_ data: Data, in range: Range<Int>) -> [(type: String, range: Range<Int>)] {
            var at = range.lowerBound, found: [(type: String, range: Range<Int>)] = []
            while at + 8 <= range.upperBound {
                let size = uint32(data, at)
                found.append((String(decoding: data[data.startIndex + at + 4..<data.startIndex + at + 8], as: UTF8.self), at..<at + size))
                at += size
            }
            return found
        }
        var data = file
        func store(_ value: Int, at offset: Int) {
            data.replaceSubrange(data.startIndex + offset..<data.startIndex + offset + 4, with: withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) })
        }
        let moof = try #require(boxes(file, in: 0..<file.count).first { $0.type == "moof" }).range
        for traf in boxes(file, in: moof.lowerBound + 8..<moof.upperBound) where traf.type == "traf" {
            for trun in boxes(file, in: traf.range.lowerBound + 8..<traf.range.upperBound) where trun.type == "trun" {
                let flags = uint32(file, trun.range.lowerBound + 8) & 0xFF_FFFF
                guard flags & 0x01 != 0 else { continue }
                store(uint32(file, trun.range.lowerBound + 16) + padding, at: trun.range.lowerBound + 16)
            }
        }
        store(moof.count + padding, at: moof.lowerBound)
        data.insert(contentsOf: withUnsafeBytes(of: UInt32(padding).bigEndian) { Data($0) } + Data("free".utf8) + Data(count: padding - 8), at: data.startIndex + moof.upperBound)
        return data
    }

    /// A fragment's sample list for a few seconds runs to kilobytes; one past a mebibyte is
    /// not read, and its samples' show times go unchecked.
    @Test("a fragmented MP4 whose first fragment is past the probe's read budget is served without that fragment read")
    func oversizedFirstFragmentIsNotRead() async throws {
        let file = try Self.paddingFirstFragment(Self.fixture("numbered-h264-fragmented-no-show-times.mp4"), by: 1 << 20)
        let reader = RecordingReader(file)

        let delivery = try await MediaDelivery.start(
            reading: reader, fileName: "clip.mp4", support: .baseline, clock: TestClock())
        let reads = reader.reads
        await delivery.stop()

        #expect(reads.allSatisfy { $0.count <= 1 << 20 }, "\(reads)")
        #expect(try await Self.route(of: file) == .served("video/mp4"))
    }

    /// A ctts whose entry count cannot be trusted is no evidence either way.
    @Test("an MP4 whose ctts entry count cannot be trusted is served", arguments: [
        // Five entries declared, none present.
        Data([0, 0, 0, 0, 0, 0, 0, 5]),
        // Four billion entries declared in a 16-byte box holding one.
        Data([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1, 0, 0, 0, 0]),
    ])
    func untrustworthyCttsIsServed(ctts: Data) async throws {
        let samples = (0..<8).map { Fixture.h264Sample(nalLengthSize: 4, sliceType: $0 == 2 ? 1 : 2) }
        let file = Fixture.h264HazardMp4(sttsEntries: [(count: 8, delta: 1000)], ctts: .raw(ctts), sampleData: samples)
        #expect(try await Self.route(of: file) == .served("video/mp4"))
    }

    /// The sample table says the show times are degenerate, but the file ends where its samples
    /// start, so no B slice can be read.
    @Test("an MP4 cut before its samples is refused as incomplete, not for a hazard its samples cannot show")
    func cutBeforeItsSamplesIsIncomplete() async throws {
        let samples = (0..<64).map { Fixture.h264Sample(nalLengthSize: 4, sliceType: $0 == 5 ? 1 : 2) }
        let file = Fixture.h264HazardMp4(
            sttsEntries: [(count: 64, delta: 1000)], ctts: .entries([(count: 32, offset: 0), (count: 32, offset: 1)]),
            sampleData: samples)
        let cut = file.prefix(file.count - samples.reduce(0) { $0 + $1.count })
        #expect(try await Self.route(of: cut) == .unplayable(.incompleteFile))
    }

    @Test("a decode-order hazard is found in the B slice behind it", arguments: [
        // 32 samples of 20 KB in one chunk, more than the 256 KiB read for B slices takes at once.
        ("samples past the read budget", (0..<32).map { index -> Data in
            let sample = Fixture.h264Sample(nalLengthSize: 4, sliceType: index == 5 ? 1 : 2)
            return sample + Data(count: 20_000 - sample.count)
        }, Fixture.StszEncoding.table, nil as Int?),
        ("a fixed-size stsz", (0..<64).map { Fixture.h264Sample(nalLengthSize: 4, sliceType: $0 == 5 ? 1 : 2) }, .fixed, nil),
        // The B slice is sample 20, in the second of two chunks of 16.
        ("a second chunk", (0..<32).map { Fixture.h264Sample(nalLengthSize: 4, sliceType: $0 == 20 ? 1 : 2) }, .table, 16),
    ])
    func decodeOrderHazardIsFound(input: String, samples: [Data], stsz: Fixture.StszEncoding, samplesPerChunk: Int?) async throws {
        let file = Fixture.h264HazardMp4(
            sttsEntries: [(count: UInt32(samples.count), delta: 1000)], ctts: .absent, sampleData: samples,
            stszEncoding: stsz, samplesPerChunk: samplesPerChunk)
        #expect(try await Self.route(of: file) == .unplayable(.directHazards([.decodeOrderTimestamps])), "\(input)")
    }

    /// Serves `data`, recording the range of each read.
    private final class RecordingReader: RandomAccessReading {
        let data: Data
        private let ranges = Mutex<[Range<UInt64>]>([])
        var reads: [Range<UInt64>] { ranges.withLock { $0 } }

        init(_ data: Data) { self.data = data }

        var fileSize: UInt64 { get async throws { UInt64(data.count) } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            ranges.withLock { $0.append(offset..<offset + UInt64(length)) }
            return try await InMemoryRandomAccessReader(data: data).read(offset: offset, length: length)
        }
    }

    /// Baseline H.264 has no B slices, so its show times need no checking against them.
    @Test("a Baseline stream's samples are not read for B slices")
    func baselineSamplesAreNotRead() async throws {
        let samples = (0..<64).map { _ in Fixture.h264Sample(nalLengthSize: 4, sliceType: 0) }
        let file = Fixture.h264HazardMp4(
            sttsEntries: [(count: 64, delta: 1000)], ctts: .absent, sampleData: samples,
            spsNALs: [Fixture.h264SPS(profileIdc: 66, frameMbsOnlyFlag: 1)])
        let samplesStart = UInt64(file.count - samples.reduce(0) { $0 + $1.count })
        let reader = RecordingReader(file)

        let delivery = try await MediaDelivery.start(
            reading: reader, fileName: "clip.mp4", support: .baseline, clock: TestClock())
        let reads = reader.reads
        await delivery.stop()

        #expect(reads.allSatisfy { $0.upperBound <= samplesStart }, "\(reads), samples from \(samplesStart)")
    }

    // MARK: - Interlacing

    @Test("an avc1 SPS's frame_mbs_only_flag decides whether the file is bridged as interlaced", arguments: [
        (66, 1, Route.served("video/mp4")), (66, 0, .refusedByTheBridge),
        // High: the SPS carries its chroma and bit-depth fields before the flag.
        (100, 1, .served("video/mp4")), (100, 0, .refusedByTheBridge),
    ])
    func interlacedH264IsBridged(profile: Int, frameMbsOnly: Int, route: Route) async throws {
        let sps = Fixture.h264SPS(profileIdc: profile, frameMbsOnlyFlag: frameMbsOnly)
        let file = Fixture.mp4(traks: [Fixture.trakRaw(stsdEntries: [Fixture.avcVideoSampleEntry(spsNALs: [sps])], handler: "vide")])
        #expect(try await Self.route(of: file) == route)
    }

    /// The probe does not parse scaling lists, so it never reaches the flag behind them, and a
    /// field-coded stream is served as it is.
    @Test("an SPS the probe cannot read to its frame_mbs_only_flag is served", arguments: [
        Fixture.h264SPS(profileIdc: 100, frameMbsOnlyFlag: 0, scalingMatrixPresent: true),
        Fixture.h264SPS(profileIdc: 66, frameMbsOnlyFlag: 0, truncated: true),
    ])
    func unreadableSPSIsServed(sps: Data) async throws {
        let file = Fixture.mp4(traks: [Fixture.trakRaw(stsdEntries: [Fixture.avcVideoSampleEntry(spsNALs: [sps])], handler: "vide")])
        #expect(try await Self.route(of: file) == .served("video/mp4"))
    }

    @Test("hvcC's interlaced and progressive source flags decide whether an HEVC file is bridged", arguments: [
        (UInt8(0x40), Route.refusedByTheBridge),
        (0x80, .served("video/mp4")),
        (0xC0, .served("video/mp4")),
        (0x00, .served("video/mp4")),
    ])
    func interlacedHEVCIsBridged(flags: UInt8, route: Route) async throws {
        let entry = Fixture.hevcVideoSampleEntry(type: "hvc1", constraintByte6: flags)
        let file = Fixture.mp4(traks: [Fixture.trakRaw(stsdEntries: [entry], handler: "vide")])
        #expect(try await Self.route(of: file) == route)
    }

    /// The bridge mends interlacing but carries decode-order show times to AVPlayer.
    @Test("an interlaced H.264 MP4 whose B-pictures would show in decode order fails with that hazard alone")
    func interlacedWithDecodeOrderShowTimesFails() async throws {
        let samples = (0..<64).map { Fixture.h264Sample(nalLengthSize: 4, sliceType: $0 == 5 ? 1 : 2) }
        let file = Fixture.h264HazardMp4(
            sttsEntries: [(count: 64, delta: 1000)], ctts: .absent, sampleData: samples,
            spsNALs: [Fixture.h264SPS(profileIdc: 77, frameMbsOnlyFlag: 0)])
        #expect(try await Self.route(of: file) == .unplayable(.directHazards([.decodeOrderTimestamps])))
    }

    // MARK: - Sample descriptions

    @Test("a padding box trailing one declared stsd entry is not read as a second one")
    func stsdPaddingIsNotASecondEntry() async throws {
        let hdlr = Data(count: 8) + Data("vide".utf8) + Data(count: 13)
        let stsd = Fixture.box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + Fixture.box("avc1") + Fixture.box("free"))
        let trak = Fixture.box("trak", Fixture.box("mdia", Fixture.box("hdlr", hdlr) + Fixture.box("minf", Fixture.box("stbl", stsd))))
        #expect(try await Self.route(of: Fixture.mp4(traks: [trak])) == .served("video/mp4"))
    }

    // MARK: - Properties

    /// The top-level boxes of an MP4 whose boxes declare 32-bit sizes.
    private static func topLevelBoxes(of file: Data) -> [Range<Int>] {
        var boxes: [Range<Int>] = []
        var offset = 0
        while offset + 8 <= file.count {
            let size = file[(file.startIndex + offset)..<(file.startIndex + offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            boxes.append(offset..<offset + size)
            offset += size
        }
        return boxes
    }

    /// A cut that ends a top-level box leaves a whole file behind it. The eight bytes of the
    /// first header are what names it an MP4.
    @Test("every prefix of a real MP4 that cuts one of its boxes is refused as incomplete, or as no container before its first eight bytes",
          arguments: [
            // Its moov last, after the samples.
            "mp4-h264.mp4",
            // Its moov first.
            "numbered-h264-rotated-90.mp4",
          ])
    func everyCutIsIncomplete(file name: String) async throws {
        let seed: UInt64 = 0x5EED_0001
        var random = SeededGenerator(seed: seed)
        let file = try Self.fixture(name)
        let boxes = Self.topLevelBoxes(of: file)
        let cuts = (0..<8) + (0..<150).map { _ -> Int in
            let box = boxes.randomElement(using: &random)!
            return Int.random(in: (box.lowerBound + 1)..<box.upperBound, using: &random)
        }

        for cut in cuts {
            let expected = cut < 8 ? Route.unplayable(.container(nil)) : .unplayable(.incompleteFile)
            #expect(try await Self.route(of: file.prefix(cut)) == expected, "cut at \(cut), seed \(seed)")
        }
    }

    /// Any change to a moov's or a first fragment's bytes, their box sizes and entry counts
    /// among them, gives a route.
    @Test("no change to a real MP4's moov or first moof makes the delivery trap", arguments: [
        // H.264 and AAC, the moov last.
        ("mp4-h264.mp4", "moov", UInt64(0x5EED_0002)),
        // H.264 alone, the moov first.
        ("numbered-h264-rotated-90.mp4", "moov", 0x5EED_0003),
        // Fragmented: the samples' times in the moof, their defaults in the moov's trex.
        ("numbered-h264-fragmented-no-show-times.mp4", "moof", 0x5EED_0004),
        ("numbered-h264-fragmented-no-show-times.mp4", "moov", 0x5EED_0005),
    ])
    func hostileBoxNeverTraps(file name: String, box type: String, seed: UInt64) async throws {
        var random = SeededGenerator(seed: seed)
        let file = try Self.fixture(name)
        let box = try #require(Self.topLevelBoxes(of: file).first {
            file[(file.startIndex + $0.lowerBound + 4)..<(file.startIndex + $0.lowerBound + 8)] == Data(type.utf8)
        })

        for index in 0..<200 {
            var mutated = file
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                // Half the words on the box's own 4-byte grid, where its fields and its children's
                // headers mostly sit.
                let at = Bool.random(using: &random)
                    ? box.lowerBound + 4 * Int.random(in: 2..<(box.count / 4 - 1), using: &random)
                    : Int.random(in: (box.lowerBound + 8)..<box.upperBound - 4, using: &random)
                let word: [UInt8] = switch Int.random(in: 0..<4, using: &random) {
                case 0: [0xFF, 0xFF, 0xFF, 0xFF]
                case 1: [0, 0, 0, 0]
                case 2: [0, 0, 0, 1]
                default: [UInt8.random(in: 0...255, using: &random)]
                }
                mutated.replaceSubrange((mutated.startIndex + at)..<(mutated.startIndex + at + word.count), with: word)
            }
            await #expect(throws: Never.self, "\(type) mutation \(index), seed \(seed)") {
                _ = try await Self.route(of: mutated)
            }
        }
    }
}

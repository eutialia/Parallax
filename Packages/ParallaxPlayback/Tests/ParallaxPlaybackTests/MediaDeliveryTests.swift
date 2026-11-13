import Foundation
import Testing
import ParallaxTestScaling
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport

@Suite("MediaDelivery", .scaledTimeLimit())
struct MediaDeliveryTests {

    /// A reader whose `read` never returns, cancellation included: a share stuck in a native
    /// socket read.
    private struct HangingReader: RandomAccessReading {
        var fileSize: UInt64 { get async throws { 1_000_000 } }
        func read(offset: UInt64, length: Int) async throws -> Data {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return Data()
        }
    }

    private static func mp4(brand: String) -> Data {
        ISOBMFFFixtures.mp4(brand: brand, traks: [
            ISOBMFFFixtures.trak(stsdEntries: ["avc1"], handler: "vide"),
            ISOBMFFFixtures.trak(stsdEntries: ["mp4a"], handler: "soun"),
        ])
    }

    @Test("a file AVPlayer plays is served whole at the delivery's URL, typed by its container",
          arguments: [("isom", "video/mp4"), ("qt  ", "video/quicktime")])
    func directFileIsServed(brand: String, contentType: String) async throws {
        let bytes = Self.mp4(brand: brand)
        let delivery = try await MediaDelivery.start(
            reading: InMemoryRandomAccessReader(data: bytes), fileName: "clip.mp4",
            support: .baseline, scope: .loopback, clock: TestClock())

        let (body, response) = try await ephemeralHTTPSession().data(from: delivery.url)
        await delivery.stop()

        #expect(body == bytes)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == contentType)
    }

    private static func fixture(_ name: String) throws -> InMemoryRandomAccessReader {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "mkv", subdirectory: "Fixtures/demux"))
        return InMemoryRandomAccessReader(data: try Data(contentsOf: url))
    }

    private static func text(at url: URL) async throws -> String {
        String(decoding: try await ephemeralHTTPSession().data(from: url).0, as: UTF8.self)
    }

    @Test("a Matroska file the bridge delivers is served as a playlist of its video and audio")
    func matroskaFileIsBridged() async throws {
        let delivery = try await MediaDelivery.start(
            reading: try Self.fixture("h264-mkvmerge"), fileName: "clip.mkv",
            support: .baseline, scope: .loopback, clock: TestClock())

        let master = try await Self.text(at: delivery.url)
        let video = try await Self.text(at: delivery.url.deletingLastPathComponent().appendingPathComponent("v.m3u8"))
        await delivery.stop()

        #expect(master.contains(#"CODECS="avc1.640014,mp4a.40.2,ac-3",RESOLUTION=160x90"#))
        #expect(video.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
            == ["v-0.m4s", "v-1.m4s", "v-2.m4s", "v-3.m4s", "v-4.m4s", "v-5.m4s"])
    }

    @Test("a Matroska file the bridge cannot deliver fails with the bridge's reason", arguments: [
        ("refused-dts-audio", BridgeRefusal.noDeliverableAudio(names: ["dts DTS"])),
        ("refused-dolby-vision-5", .videoCodec(name: "hevc Main 10, Dolby Vision profile 5")),
        // The baseline device has no AV1 or 10-bit H.264 decoder.
        ("av1", .videoCodec(name: "av1 Main")),
        ("h264-high10", .videoCodec(name: "h264 High 10")),
    ])
    func refusedMatroskaFileThrowsTheBridgesReason(name: String, reason: BridgeRefusal) async throws {
        let reader = try Self.fixture(name)
        await #expect(throws: Unplayable.refused(reason)) {
            _ = try await MediaDelivery.start(
                reading: reader, fileName: "clip.mkv", support: .baseline, scope: .loopback, clock: TestClock())
        }
    }

    @Test("bytes that only start like Matroska are refused as unreadable, not reported as a failed read")
    func damagedMatroskaFileIsRefused() async {
        let matroska = Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60))

        await #expect {
            _ = try await MediaDelivery.start(
                reading: InMemoryRandomAccessReader(data: matroska), fileName: "clip.mkv",
                support: .baseline, scope: .loopback, clock: TestClock())
        } throws: {
            if case Unplayable.refused(.unreadable) = $0 { true } else { false }
        }
    }

    @Test("a refusal reads as one line that names what the file holds", arguments: [
        ("h264-high10", "video: h264 High 10"),
        ("refused-dts-audio", "audio: dts DTS"),
        ("refused-one-keyframe", "no keyframe index"),
    ])
    func refusalReadsAsOneLine(name: String, line: String) async throws {
        let reader = try Self.fixture(name)
        await #expect {
            _ = try await MediaDelivery.start(
                reading: reader, fileName: "clip.mkv", support: .baseline, scope: .loopback, clock: TestClock())
        } throws: { "\($0)" == line }
    }

    @Test("a PQ file is refused with a reason where HDR does not show and bridged where it does, and HLG is bridged on both")
    func pqFileNeedsAnHDRDisplay() async throws {
        let reader = try Self.fixture("hdr-pq")
        await #expect {
            _ = try await MediaDelivery.start(
                reading: reader, fileName: "clip.mkv", support: .baseline, showsHDR: false, scope: .loopback,
                clock: TestClock())
        } throws: { "\($0)" == "video: PQ, and this display shows no HDR" }

        let delivery = try await MediaDelivery.start(
            reading: reader, fileName: "clip.mkv", support: .baseline, showsHDR: true, scope: .loopback,
            clock: TestClock())
        let master = try await Self.text(at: delivery.url)
        await delivery.stop()
        #expect(master.contains("VIDEO-RANGE=PQ"))

        // AVPlayer plays HLG where HDR does not show, measured on a Mac with an SDR display.
        let hlg = try await MediaDelivery.start(
            reading: try Self.fixture("hdr-hlg"), fileName: "clip.mkv", support: .baseline, showsHDR: false,
            scope: .loopback, clock: TestClock())
        let hlgMaster = try await Self.text(at: hlg.url)
        await hlg.stop()
        #expect(hlgMaster.contains("VIDEO-RANGE=HLG"))
    }

    private struct ShareGone: Error {}

    /// Serves the file until its `limit`th read, which throws, as does every read after it.
    private actor FailingReader: RandomAccessReading {
        private let backing: InMemoryRandomAccessReader
        private let limit: Int
        private(set) var reads = 0

        init(_ backing: InMemoryRandomAccessReader, failingFromRead limit: Int = .max) {
            self.backing = backing
            self.limit = limit
        }

        var fileSize: UInt64 { get async throws { try await backing.fileSize } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            reads += 1
            if reads >= limit { throw ShareGone() }
            return try await backing.read(offset: offset, length: length)
        }
    }

    @Test("a share that goes away at any read while a Matroska file opens is a failed read, never a refused file")
    func shareLostWhileBridgingIsAFailedRead() async throws {
        let file = try Self.fixture("h264-mkvmerge")
        let counting = FailingReader(file)
        let delivery = try await MediaDelivery.start(
            reading: counting, fileName: "clip.mkv", support: .baseline, scope: .loopback, clock: TestClock())
        await delivery.stop()
        let readsToOpen = await counting.reads
        try #require(readsToOpen > 3)

        for failing in 1...readsToOpen {
            await #expect("read \(failing) of \(readsToOpen)") {
                let delivery = try await MediaDelivery.start(
                    reading: FailingReader(file, failingFromRead: failing), fileName: "clip.mkv",
                    support: .baseline, scope: .loopback, clock: TestClock())
                await delivery.stop()
            } throws: {
                guard case MediaDelivery.ProbeFailure.unreadable(let underlying) = $0 else { return false }
                return underlying is ShareGone
            }
        }
    }

    @Test("without bridging, a Matroska file is a container AVPlayer cannot open")
    func matroskaFileIsNotBridgedWhenToldNotTo() async throws {
        let reader = try Self.fixture("h264-mkvmerge")
        await #expect(throws: Unplayable.container(.mkv)) {
            _ = try await MediaDelivery.start(
                reading: reader, fileName: "clip.mkv", support: .baseline, bridging: false,
                scope: .loopback, clock: TestClock())
        }
    }

    @Test("a wedged source is abandoned at the probe deadline")
    func wedgedSourceTimesOut() async throws {
        let clock = TestClock()
        let start = Task {
            try await MediaDelivery.start(
                reading: HangingReader(), fileName: "clip.mp4", support: .baseline,
                scope: .loopback, probeDeadline: .seconds(4), clock: clock)
        }
        try await clock.waitForSleep(dueIn: .seconds(4))
        clock.advance(by: .seconds(4))

        await #expect { _ = try await start.value } throws: {
            if case MediaDelivery.ProbeFailure.timedOut = $0 { true } else { false }
        }
    }

    @Test("a source that fails its reads surfaces the reader's own error, not a timeout")
    func unreadableSourceKeepsItsError() async {
        struct RefusingReader: RandomAccessReading {
            var fileSize: UInt64 { get async throws { throw POSIXError(.ENOENT) } }
            func read(offset: UInt64, length: Int) async throws -> Data { throw POSIXError(.ENOENT) }
        }

        await #expect {
            _ = try await MediaDelivery.start(
                reading: RefusingReader(), fileName: "clip.mp4", support: .baseline,
                scope: .loopback, clock: TestClock())
        } throws: {
            guard case MediaDelivery.ProbeFailure.unreadable(let underlying) = $0 else { return false }
            return (underlying as? POSIXError)?.code == .ENOENT
        }
    }
}

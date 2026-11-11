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

    @Test("a file AVPlayer cannot play fails with its reason")
    func unplayableFileThrowsItsReason() async {
        let matroska = Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60))

        await #expect(throws: Unplayable.container(.mkv)) {
            _ = try await MediaDelivery.start(
                reading: InMemoryRandomAccessReader(data: matroska), fileName: "clip.mkv",
                support: .baseline, scope: .loopback, clock: TestClock())
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

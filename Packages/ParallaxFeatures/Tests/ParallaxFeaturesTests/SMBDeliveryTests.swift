import Foundation
import os
import Testing
import ParallaxTestScaling
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxFileBrowse
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxFeatures

/// What `SMBDelivery` adds over `MediaDelivery` is who releases the pooled reader, and when.
@Suite("SMBDelivery", .scaledTimeLimit())
struct SMBDeliveryTests {

    /// Records how its borrow was ended and runs a test-supplied check at drain time. With
    /// `hangs` set, its reads never return, cancellation included.
    private actor FakeReader: SMBShareReading {
        private let data: Data
        private let hangs: Bool
        private var atDrain: (@Sendable () async -> Void)?
        private(set) var releases: [String] = []
        let hadTransportFault = false

        init(data: Data, hangs: Bool = false) {
            self.data = data
            self.hangs = hangs
        }

        func setAtDrain(_ check: @escaping @Sendable () async -> Void) { atDrain = check }

        var fileSize: UInt64 { get async throws { UInt64(data.count) } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            if hangs { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
            guard offset < UInt64(data.count), length > 0 else { return Data() }
            let start = Int(offset)
            return data.subdata(in: start..<min(start + length, data.count))
        }

        func drainAndDisconnect() async {
            releases.append("drain")
            await atDrain?()
        }

        func disconnect() async { releases.append("disconnect") }
        func markUnreusable() async { releases.append("markUnreusable") }
        func teardownCapturingTransportFault() async -> Bool {
            releases.append("teardown")
            return false
        }
    }

    private static func fetch(_ url: URL) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CITimeScale.interval(10)
        return (try? await URLSession(configuration: configuration).data(from: url)) != nil
    }

    @Test("stop closes the URL before the reader is drained")
    func stopClosesTheURLBeforeDrainingTheReader() async throws {
        let reader = FakeReader(data: AppWorld.mp4Bytes)
        let delivery = try await SMBDelivery.start(
            reader: reader, fileName: "clip.mp4", support: .baseline, scope: .loopback, clock: TestClock())
        #expect(await Self.fetch(delivery.url))

        let servedAtDrain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        await reader.setAtDrain { [url = delivery.url] in
            let served = await Self.fetch(url)
            servedAtDrain.withLock { $0 = served }
        }

        await delivery.stop()

        #expect(await reader.releases == ["drain"])
        #expect(servedAtDrain.withLock { $0 } == false)
    }

    @Test("a file AVPlayer cannot play releases the reader before the reason is thrown")
    func unplayableFileReleasesTheReader() async {
        let reader = FakeReader(data: AppWorld.mkvBytes)

        await #expect(throws: Unplayable.container(.mkv)) {
            _ = try await SMBDelivery.start(
                reader: reader, fileName: "clip.mkv", support: .baseline, scope: .loopback, clock: TestClock())
        }

        #expect(await reader.releases == ["drain"])
    }

    @Test("a reader wedged past the probe deadline is torn down without waiting on its read")
    func wedgedReaderIsTornDownNotDrained() async throws {
        let reader = FakeReader(data: AppWorld.mp4Bytes, hangs: true)
        let clock = TestClock()
        let start = Task {
            try await SMBDelivery.start(
                reader: reader, fileName: "clip.mp4", support: .baseline, scope: .loopback,
                probeDeadline: .seconds(4), clock: clock)
        }
        try await clock.waitForSleep(dueIn: .seconds(4))
        clock.advance(by: .seconds(4))

        await #expect { _ = try await start.value } throws: {
            if case SMBDelivery.ProbeFailure.timedOut = $0 { true } else { false }
        }
        #expect(await reader.releases == ["teardown"])
    }
}

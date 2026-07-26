import Foundation
import os
import Testing
import ParallaxCore
@testable import ParallaxFileBrowse

/// The session is a passive holder, so what there is to pin is the ORDER-SENSITIVE teardown and the
/// self-teardown on a failed start. A fake reader stands in for the SMB side and reports what the
/// bridge's state was at the instant it was drained.
@Suite("SMBBridgeSession")
struct SMBBridgeSessionTests {

    /// Records every `drainAndDisconnect`, and runs a test-supplied probe at drain time so the test
    /// can observe whether the bridge had already been stopped when the reader's turn came.
    private actor FakeBridgeReader: SMBBridgeReading {
        private let data: Data
        private var probe: (@Sendable () async -> Void)?
        private(set) var drainCount = 0

        init(data: Data) { self.data = data }

        func setProbe(_ probe: @escaping @Sendable () async -> Void) { self.probe = probe }

        var fileSize: UInt64 { get async throws { UInt64(data.count) } }

        func read(offset: UInt64, length: Int) async throws -> Data {
            guard offset < UInt64(data.count), length > 0 else { return Data() }
            let start = Int(offset)
            return data.subdata(in: start..<min(start + length, data.count))
        }

        func drainAndDisconnect() async {
            drainCount += 1
            await probe?()
        }
    }

    private static let payload = Data((0..<2_048).map { UInt8($0 % 251) })

    private func makeSession() -> (SMBBridgeSession, FakeBridgeReader) {
        let reader = FakeBridgeReader(data: Self.payload)
        return (SMBBridgeSession(reader: reader, fileName: "video.mp4", contentType: "video/mp4"), reader)
    }

    @Test("start returns a URL that serves the reader's bytes")
    func startServesTheReader() async throws {
        let (session, _) = makeSession()
        let url = try await session.start(scope: .loopback)

        let (body, response) = try await ephemeralHTTPSession().data(from: url)
        await session.stop()

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Self.payload)
    }

    /// Bridge FIRST, reader second: inverting the order would hand a live serve loop a connection
    /// that has already been checked back into the pool. The reader's drain-time probe asks the
    /// bridge to start again — `.stopped` (not `.alreadyStarted`) proves the bridge went down first.
    @Test("stop tears the bridge down before draining the reader")
    func stopStopsTheBridgeBeforeTheReader() async throws {
        let (session, reader) = makeSession()
        _ = try await session.start(scope: .loopback)

        let observed = OSAllocatedUnfairLock<SMBHTTPBridge.BridgeError?>(initialState: nil)
        await reader.setProbe { [bridge = session.bridge] in
            do {
                _ = try await bridge.start(scope: .loopback)
            } catch {
                observed.withLock { $0 = error as? SMBHTTPBridge.BridgeError }
            }
        }

        await session.stop()

        #expect(await reader.drainCount == 1)
        #expect(observed.withLock { $0 } == .stopped, "the bridge must already be stopped when the reader is drained")
    }

    @Test("a failed start tears the session down before rethrowing")
    func failedStartSelfTearsDown() async throws {
        let (session, reader) = makeSession()
        _ = try await session.start(scope: .loopback)

        // A second start on the same bridge is the reachable start failure.
        await #expect(throws: SMBHTTPBridge.BridgeError.alreadyStarted) {
            _ = try await session.start(scope: .loopback)
        }

        #expect(await reader.drainCount == 1, "nothing else will ever own the session — it must clean up")
    }

    @Test("stats read through to the bridge, and survive stop()")
    func statsReadThroughAfterStop() async throws {
        let (session, _) = makeSession()
        let url = try await session.start(scope: .loopback)

        var request = URLRequest(url: url)
        request.setValue("bytes=0-511", forHTTPHeaderField: "Range")
        let (body, _) = try await ephemeralHTTPSession().data(for: request)
        #expect(body.count == 512)

        await session.stop()

        let stats = await session.stats
        #expect(stats.bytesRead == 512)
        #expect(stats.connections == 1)
    }
}

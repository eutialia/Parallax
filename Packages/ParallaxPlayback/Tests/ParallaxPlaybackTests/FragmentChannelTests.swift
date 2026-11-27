import Foundation
import Testing
@testable import ParallaxPlayback

/// No case at `MediaDelivery` reaches these. A put waits on a full channel only behind a client
/// that stops reading a segment larger than the socket buffers, which no fixture has, and a
/// failure lands before the server's next take only when it wins a race against the send.
@Suite("FragmentChannel", .timeLimit(.minutes(1)))
struct FragmentChannelTests {

    /// `body` on a thread of its own, as a demuxer's queue runs a segment.
    private static func onThread(_ body: @escaping @Sendable () throws -> Void) async -> Result<Void, any Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: Result { try body() }) }
        }
    }

    @Test("a cancel wakes a put waiting on a full channel, which then throws")
    func cancelWakesAWaitingPut() async throws {
        let channel = FragmentChannel(heldChanged: { _ in })
        let producing = Task {
            await Self.onThread {
                try channel.put(Data("one".utf8))
                try channel.put(Data("two".utf8))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        channel.cancel()

        await #expect(throws: CancellationError.self) { try await producing.value.get() }
        await #expect(throws: CancellationError.self) { _ = try await channel.next() }
    }

    @Test("a segment that fails after its fragments hands them over, then the failure")
    func failureComesAfterTheFragments() async throws {
        struct Broken: Error {}
        let channel = FragmentChannel(heldChanged: { _ in })
        async let producing = Self.onThread {
            try channel.put(Data("one".utf8))
            channel.finish(.failure(Broken()))
        }

        #expect(try await channel.next() == Data("one".utf8))
        await #expect(throws: Broken.self) { _ = try await channel.next() }
        try await producing.get()
    }
}

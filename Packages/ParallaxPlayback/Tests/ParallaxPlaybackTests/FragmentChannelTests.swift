import Foundation
import Synchronization
import Testing
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("FragmentChannel", .scaledTimeLimit())
struct FragmentChannelTests {

    /// `body` on a thread of its own, as a demuxer's queue runs a segment.
    private static func onThread(_ body: @escaping @Sendable () throws -> Void) async -> Result<Void, any Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: Result { try body() }) }
        }
    }

    @Test("fragments come out in the order they were put, then the end, and a put waits while one is not yet taken")
    func fragmentsComeOutInOrderAndAPutWaits() async throws {
        let channel = FragmentChannel()
        let secondPut = Atomic(false)
        async let producing = Self.onThread {
            try channel.put(Data("one".utf8))
            try channel.put(Data("two".utf8))
            secondPut.store(true, ordering: .sequentiallyConsistent)
            channel.finish(.success(()))
        }
        // Time for the second put to return, were it not waiting.
        try await Task.sleep(for: .milliseconds(50))
        let returnedEarly = secondPut.load(ordering: .sequentiallyConsistent)
        #expect(!returnedEarly)

        var taken: [Data?] = []
        for _ in 0..<3 { taken.append(try await channel.next()) }
        try await producing.get()

        #expect(taken == [Data("one".utf8), Data("two".utf8), nil])
    }

    @Test("a cancel wakes a put waiting on a full channel, which then throws")
    func cancelWakesAWaitingPut() async throws {
        let channel = FragmentChannel()
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
        let channel = FragmentChannel()
        async let producing = Self.onThread {
            try channel.put(Data("one".utf8))
            channel.finish(.failure(Broken()))
        }

        #expect(try await channel.next() == Data("one".utf8))
        await #expect(throws: Broken.self) { _ = try await channel.next() }
        try await producing.get()
    }
}

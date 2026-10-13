import Foundation
import CoreMedia
import Testing
import ParallaxPlayback
import ParallaxPlaybackTestSupport

/// Only the double's *consumer-visible async contract* is pinned here — the stream
/// lifecycle and the call log — because that is what every `PlayerViewModel` test in
/// the app target reads. Field echoes (id/capabilities/selected-track getters) are
/// deliberately absent: asserting a stub returns what it was handed catches nothing.
@Suite("FakePlaybackEngine contract")
@MainActor
struct FakePlaybackEngineTests {

    @Test("load records the asset and pushed states reach a for-await consumer in order")
    func loadRecordsAsset() async throws {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let url = URL(string: "https://example.com/stream.mp4")!
        let asset = PlayableAsset.fixture(url: url)

        var received: [PlaybackState] = []
        let task = Task {
            for await beat in fake.state {
                received.append(beat.state)
                if received.count == 3 { break }
            }
        }

        try await fake.load(asset)
        let duration = CMTime(seconds: 3600, preferredTimescale: 1000)
        fake.push(.loading)
        fake.push(.ready(duration: duration, tracks: .empty))

        await task.value

        #expect(fake.loadedAssets.map(\.url) == [url])
        #expect(received.count == 3)
        guard case .idle = received[0] else {
            Issue.record("Expected the seeded .idle first, got \(received[0])"); return
        }
        guard case .loading = received[1] else {
            Issue.record("Expected .loading second, got \(received[1])"); return
        }
        guard case .ready(let d, _) = received[2] else {
            Issue.record("Expected .ready third, got \(received[2])"); return
        }
        #expect(d == duration)
    }

    /// The formatted log strings ARE the fake's published contract — `PlayerViewModelTests`
    /// asserts on `calls.contains("seek(3000.0)")` and friends — so the literals here are
    /// the spec, not a re-derivation.
    @Test("play/pause/seek/teardown append to the call log in order")
    func callOrder() async throws {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        try await fake.load(.fixture(url: URL(string: "https://example.com/stream.mp4")!))
        await fake.play()
        await fake.pause()
        await fake.seek(to: CMTime(seconds: 30, preferredTimescale: 1000))
        await fake.teardown()
        #expect(fake.calls == ["load", "play", "pause", "seek(30.0)", "teardown"])
    }

    @Test("before load a seek is a no-op, and a play is flagged as a test bug")
    func transportBeforeLoad() async {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        await fake.seek(to: CMTime(seconds: 30, preferredTimescale: 1000))
        await withKnownIssue { await fake.play() }
        #expect(fake.calls == [])
        #expect(!fake.isPlayingNow)
    }

    @Test("a fake that lands seeks answers one with an observed beat at the target, in the loaded session")
    func landedSeekPublishesTheTarget() async throws {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        fake.landsSeeks = true
        var beats: [PlaybackBeat] = []
        let consumer = Task {
            for await beat in fake.state { beats.append(beat) }
        }
        let session = try await fake.load(.fixture(url: URL(string: "https://example.com/stream.mp4")!))
        let duration = CMTime(seconds: 3600, preferredTimescale: 1000)
        fake.push(.ready(duration: duration, tracks: .empty))
        await fake.play()

        await fake.seek(to: CMTime(seconds: 90, preferredTimescale: 1000))
        try await fake.settle()

        guard let last = beats.last, case .playing(let position, let reported, nil, .observed) = last.state else {
            Issue.record("the seek published \(String(describing: beats.last)) instead of an observed landing")
            return
        }
        #expect(CMTimeGetSeconds(position) == 90)
        #expect(reported == duration)
        #expect(last.session == session)
        await fake.teardown()
        await consumer.value
    }

    /// The barrier every `PlayerViewModel` suite leans on instead of a `Task.sleep`:
    /// when `settle()` returns, the consumer's loop body has RUN for each pushed state
    /// (not merely received it) — here proven by the body's own slow `await` landing in
    /// `handled` before the assertion.
    @Test("settle() returns only after the consumer's loop body ran for every pushed state")
    func settleWaitsForConsumerBody() async throws {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        var handled: [PlaybackState] = []
        let task = Task {
            for await beat in fake.state {
                await Task.yield()   // a body that suspends must still be waited out
                handled.append(beat.state)
            }
        }

        fake.push(.loading)
        try await fake.settle()
        #expect(handled.count == 2)   // the seeded .idle, then .loading

        fake.push(.ended)
        try await fake.settle()
        #expect(handled.count == 3)

        await fake.teardown()
        await task.value
    }

    @Test("settle() throws instead of hanging when no one consumes the stream")
    func settleTimesOutWithoutConsumer() async throws {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        await #expect(throws: FakePlaybackEngine.SettleTimeout.self) {
            try await fake.settle(timeout: .milliseconds(20))
        }
    }

    @Test("teardown finishes the state stream after delivering every pushed state")
    func teardownFinishesStream() async {
        let fake = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        var count = 0
        let task = Task {
            for await _ in fake.state { count += 1 }
        }
        fake.push(.loading)
        await fake.teardown()
        await task.value
        #expect(count == 2)   // the seeded .idle, then .loading
    }
}

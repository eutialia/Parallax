import Foundation
import Synchronization
import Testing
import ParallaxCore
@testable import ParallaxPlayback

/// What a demuxer does that a delivery of the fixtures cannot show: no decoder stops giving
/// pictures.
@Suite("MediaDemuxer", .timeLimit(.minutes(1)))
struct MediaDemuxerTests {

    /// Takes every packet and never has enough: a decoder that gives no more pictures.
    private final class UnsatisfiedSink: PacketSink, Sendable {
        let times = Mutex([Int64]())
        var isCancelled: Bool { false }
        var isSatisfied: Bool { false }
        func accept(_ packet: MediaPacket) {
            times.withLock { $0 += [packet.presentationTime].compactMap(\.self) }
        }
    }

    @Test("a video read whose sink never has enough runs past its span and stops at the first keyframe two seconds on")
    func videoReadRunsOnOnlySoFar() async throws {
        let demuxer = try await BridgeFixture.demuxer("numbered-mpeg2-open-gop.ts")
        let keyframes = try await demuxer.keyframes()
        let upper = keyframes[1].time
        let stop = try #require(keyframes.first { $0.time - upper >= 2_000_000_000 })
        try #require(stop.time < keyframes[keyframes.count - 1].time)
        let sink = UnsatisfiedSink()

        try await demuxer.read(demuxer.videoStream, from: 0, to: 1, into: sink)

        let latest = try #require(sink.times.withLock { $0.max() })
        #expect(latest >= upper)
        #expect(latest < stop.time)
    }
}

import Foundation
import ParallaxCore
import Testing
@testable import ParallaxPlayback

/// What no test host shows: a device with no HEVC encoder, and a keyframe a read gives no
/// presentation time.
@Suite("Converted video")
struct ConvertedVideoTests {
    @Test("a file whose video has to be converted is refused by name on a device with no HEVC encoder")
    func noEncoderRefusesTheFile() async throws {
        let demuxer = try await BridgeFixture.demuxer("numbered-vp9")

        await #expect(throws: BridgeRefusal.videoEncoder(name: "vp9 Profile 0")) {
            _ = try await BridgePlan(reading: demuxer, support: BridgeFixture.fewestDecoders, showsHDR: true) { _ in
                throw HEVCEncoder.Failure.session(code: -12908)
            }
        }
        #expect("\(BridgeRefusal.videoEncoder(name: "vp9 Profile 0"))" == "video: vp9 Profile 0, and this device has no HEVC encoder")
    }

    /// A keyframe may come back with no presentation time from a read after a seek. No clip
    /// does it under the seek spans use, so the packet here has its time taken away.
    @Test("a program stream's keyframe with no presentation time is decoded at the time it was listed at")
    func untimedKeyframeDecodesAtItsListedTime() async throws {
        let demuxer = try await MediaDemuxer.open(
            InMemoryRandomAccessReader(data: try BridgeFixture.data("numbered-mpeg2-mp2.mpg")))
        let keyframes = try await demuxer.keyframes()
        let video = demuxer.videoStream
        let packets = try await demuxer.packets(video, from: 4, to: 6)
        let first = try #require(packets.first)
        let untimed = MediaPacket(
            stream: first.stream, presentationTime: nil, decodeTime: first.decodeTime, duration: first.duration,
            isKeyframe: first.isKeyframe, data: first.data, primingSamples: first.primingSamples)

        let decoder = try VideoDecoder(demuxer.streams[video].parameters, timedByDecodeOrder: false)
        var times: [Int64] = []
        for packet in [untimed] + packets.dropFirst() { try decoder.decode(packet) { times.append($0.pointee.pts) } }

        #expect(times.first == keyframes[4].time)
    }
}

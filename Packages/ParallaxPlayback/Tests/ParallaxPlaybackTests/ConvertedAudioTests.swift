import Foundation
import Testing
@testable import ParallaxPlayback

/// A WMA Pro opening, which no file a test host can make holds: ffmpeg does not encode WMA Pro.
@Suite("Converted audio")
struct ConvertedAudioTests {
    @Test("a stream whose opening decodes to frames with no time starts at its first packet's time")
    func untimedOpeningStartsAtItsFirstPacket() async throws {
        let demuxer = try await BridgeFixture.demuxer("vorbis")
        let stream = try #require(demuxer.streams.first { $0.kind == .audio })
        let packets = try await demuxer.packets(stream.index, from: 0, to: 1)
        // A Vorbis decoder gives nothing for its first packet, so no frame is timed.
        let untimed = packets.enumerated().map { index, packet in
            MediaPacket(
                stream: packet.stream, presentationTime: index == 0 ? 40_000_000 : nil, decodeTime: nil,
                duration: packet.duration, isKeyframe: packet.isKeyframe, data: packet.data)
        }

        #expect(ConvertedAudio(stream, openingWith: untimed)?.start == 40_000_000)
    }
}

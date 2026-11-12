import Foundation
import Testing
import ParallaxCore
@testable import ParallaxPlayback

/// The media bridge's fixtures, written by `scripts/gen-demux-fixtures.sh`.
enum BridgeFixture {
    static func data(_ name: String, _ ext: String = "mkv") throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: ext, subdirectory: "Fixtures/demux"))
        return try Data(contentsOf: url)
    }

    static func demuxer(_ name: String) async throws -> MediaDemuxer {
        try await MediaDemuxer.open(InMemoryRandomAccessReader(data: data(name)))
    }

    /// ffprobe's md5 and keyframe flag of each packet of one stream, in file order.
    static func sourcePackets(_ name: String, stream: Int) throws -> [SourcePacket] {
        let rows = try #require(JSONSerialization.jsonObject(with: data(name, "packets.json")) as? [[Any]])
        return try rows.filter { $0[0] as? Int == stream }.map {
            SourcePacket(md5: try #require($0[4] as? String), isKeyframe: try #require($0[3] as? Bool))
        }
    }

    struct SourcePacket: Equatable {
        let md5: String
        let isKeyframe: Bool
    }
}

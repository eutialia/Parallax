import ParallaxCoreTestSupport
import ParallaxPlayback
import Testing

/// An AVKit option index, a Jellyfin stream index and a stream's place in the played file are all
/// plain integers, and passing one for another once selected the wrong track.
@Suite("Track ids")
struct TrackIDProperties {

    private static let cases = 500

    @Test("a track id gives back its own index and never reads as another kind")
    func eachIdKeepsItsOwnIndex() {
        var random = SeededGenerator(seed: 0x74_6964)
        for run in 0..<Self.cases {
            let index = Int.random(in: Int.min...Int.max, using: &random)

            let indexes: [(TrackID) -> Int?] = [\.avKitOptionIndex, \.jellyfinStreamIndex, \.fileStreamIndex]
            let ids: [TrackID] = [.avKitOption(index), .jellyfinStream(index), .fileStream(index)]
            for (own, id) in ids.enumerated() {
                #expect(indexes.map { $0(id) } == indexes.indices.map { $0 == own ? index : nil }, "run \(run): \(id)")
            }
        }
    }
}

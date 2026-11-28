import ParallaxCoreTestSupport
import ParallaxPlayback
import Testing

/// An AVKit option index and a Jellyfin stream index are both plain integers, and passing one for
/// the other once selected the wrong track.
@Suite("Track ids")
struct TrackIDProperties {

    private static let cases = 500

    @Test("a track id gives back its own index and never reads as the other kind")
    func eachIdKeepsItsOwnIndex() {
        var random = SeededGenerator(seed: 0x74_6964)
        for run in 0..<Self.cases {
            let index = Int.random(in: Int.min...Int.max, using: &random)

            #expect(TrackID.avKitOption(index).avKitOptionIndex == index, "run \(run)")
            #expect(TrackID.avKitOption(index).jellyfinStreamIndex == nil, "run \(run)")
            #expect(TrackID.jellyfinStream(index).jellyfinStreamIndex == index, "run \(run)")
            #expect(TrackID.jellyfinStream(index).avKitOptionIndex == nil, "run \(run)")
        }
    }
}

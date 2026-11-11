import Foundation
import Testing
import ParallaxPlayback

/// An AVKit option index and a Jellyfin source-stream index are both plain integers, and
/// passing one for the other selected the wrong track. Every accessor answers `nil` for the
/// foreign namespace.
@Suite("TrackID namespaces")
struct TrackIDTests {

    @Test("avKitOptionIndex unwraps the option index")
    func avKitOptionIndex() {
        #expect(TrackID.avKitOption(7).avKitOptionIndex == 7)
        #expect(TrackID.jellyfinStream(7).avKitOptionIndex == nil)
    }

    @Test("jellyfinStreamIndex unwraps the source-stream index")
    func jellyfinStreamIndex() {
        #expect(TrackID.jellyfinStream(3).jellyfinStreamIndex == 3)
        #expect(TrackID.avKitOption(3).jellyfinStreamIndex == nil)
    }
}

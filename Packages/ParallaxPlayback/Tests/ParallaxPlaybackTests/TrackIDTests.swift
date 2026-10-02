import Foundation
import Testing
import ParallaxPlayback

/// `TrackID` exists to make one specific bug impossible: before it, an AVKit option
/// index ("2") and a Jellyfin source-stream index ("2") were both bare `String`s, so
/// feeding one where the other was expected silently selected the wrong track. Every
/// accessor must therefore answer `nil` for a foreign namespace — that, not the happy
/// unwrap, is the contract.
@Suite("TrackID namespaces")
struct TrackIDTests {

    @Test("avKitOptionIndex unwraps the option index")
    func avKitOptionIndex() {
        #expect(TrackID.avKitOption(7).avKitOptionIndex == 7)
        #expect(TrackID.vlc("7").avKitOptionIndex == nil)
        #expect(TrackID.jellyfinStream(7).avKitOptionIndex == nil)
    }

    @Test("vlcTrackID unwraps the VLC trackId string")
    func vlcTrackID() {
        #expect(TrackID.vlc("a1").vlcTrackID == "a1")
        #expect(TrackID.avKitOption(1).vlcTrackID == nil)
        #expect(TrackID.jellyfinStream(1).vlcTrackID == nil)
    }

    @Test("jellyfinStreamIndex unwraps the source-stream index")
    func jellyfinStreamIndex() {
        #expect(TrackID.jellyfinStream(3).jellyfinStreamIndex == 3)
        #expect(TrackID.avKitOption(3).jellyfinStreamIndex == nil)
        #expect(TrackID.vlc("3").jellyfinStreamIndex == nil)
    }
}

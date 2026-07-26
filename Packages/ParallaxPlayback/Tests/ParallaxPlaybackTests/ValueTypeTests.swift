import Foundation
import Testing
import ParallaxPlayback

@Suite("Value types")
struct ValueTypeTests {

    /// The raw strings are a persistence contract: they are what the app writes into
    /// its stored per-source engine preference, so renaming a case must not silently
    /// change the on-disk value.
    @Test("PlaybackEngineID raw values are the persisted identifiers")
    func playbackEngineIDRawValues() {
        #expect(PlaybackEngineID.avKit.rawValue == "avKit")
        #expect(PlaybackEngineID.vlcKit.rawValue == "vlcKit")
    }

    /// `.empty` is what every engine publishes before an inventory resolves, so the
    /// track menus must be able to trust it as "nothing to show, nothing selected".
    @Test("TrackInventory.empty carries no tracks and no selection")
    func trackInventoryEmpty() {
        let inv = TrackInventory.empty
        #expect(inv.audio.isEmpty)
        #expect(inv.subtitles.isEmpty)
        #expect(inv.selectedAudioID == nil)
        #expect(inv.selectedSubtitleID == nil)
    }
}

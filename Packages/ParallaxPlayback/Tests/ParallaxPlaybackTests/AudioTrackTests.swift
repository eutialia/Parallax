import Foundation
import Testing
import ParallaxPlayback

/// The player's audio chip shows "English 7.1" — the language plus the layout, WITHOUT
/// the codec the menu's detail line already carries. `channelLabel` is the split that
/// makes that possible, by re-reading the "codec · channels" detail string.
@Suite("AudioTrack.channelLabel")
struct AudioTrackTests {

    private func track(detail: String?) -> AudioTrack {
        AudioTrack(id: .vlc("a1"), displayName: "English", languageCode: "en", detailLabel: detail)
    }

    @Test("takes the layout half of a codec · channels detail line", arguments: [
        ("TrueHD · 7.1", "7.1"),
        ("Dolby Digital+ · 5.1", "5.1"),
        ("AAC · Stereo", "Stereo"),
        ("DTS-HD MA · Mono", "Mono"),
    ])
    func extractsChannels(detail: String, expected: String) {
        #expect(track(detail: detail).channelLabel == expected)
    }

    /// Nil where the chip must fall back to the language name alone: the VLC inventory
    /// and direct-play paths have no server metadata, so there is no detail line — and a
    /// codec-only line carries no layout to show.
    @Test("nil when there is no layout to show", arguments: [
        String?.none,          // VLC inventory / direct-play: no server metadata
        "TrueHD",              // codec only, no separator
        "",                    // present but empty
        "TrueHD · ",           // separator with an empty layout half
    ])
    func nilWithoutALayout(detail: String?) {
        #expect(track(detail: detail).channelLabel == nil)
    }

    /// Whitespace around the separator is the server's, not ours — it must be trimmed
    /// off rather than shipped into the chip.
    @Test("trims the whitespace the server pads the separator with")
    func trimsWhitespace() {
        #expect(track(detail: "TrueHD·7.1").channelLabel == "7.1")
        #expect(track(detail: "TrueHD   ·   7.1").channelLabel == "7.1")
    }

    /// The transcode flags travel with the track so the menu can mark a re-encoded
    /// rendition; they default to "delivered as-is" (Direct Play).
    @Test("a plainly-constructed track is not marked as a transcode")
    func defaultsToDirectPlay() {
        let plain = AudioTrack(id: .vlc("a1"), displayName: "English", languageCode: "en")
        #expect(plain.isTranscode == false)
        #expect(plain.transcodeTarget == nil)
        #expect(plain.detailLabel == nil)
    }
}

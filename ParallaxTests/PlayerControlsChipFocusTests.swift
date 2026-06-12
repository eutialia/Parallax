import CoreGraphics
import Testing
@testable import Parallax

/// Pins the playhead→chip mapping behind the tvOS chip row's `defaultFocus`:
/// moving focus down from the scrubber must land on the chip nearest the
/// progress dot, not the focus engine's geometric screen-center pick.
@Suite("Chip row playhead focus")
struct PlayerControlsChipFocusTests {
    private typealias Kind = PlayerControlsView.TrackMenuKind

    /// A realistic tvOS chip row in "hud" coordinates:
    /// audio · subtitles · speed · chapters, left to right.
    private let frames: [Kind: CGRect] = [
        .audio: CGRect(x: 200, y: 980, width: 220, height: 56),
        .subtitles: CGRect(x: 440, y: 980, width: 260, height: 56),
        .speed: CGRect(x: 720, y: 980, width: 120, height: 56),
        .chapters: CGRect(x: 860, y: 980, width: 180, height: 56),
    ]

    @Test("playhead over each chip's center picks that chip")
    func centersMapToTheirChips() {
        for (kind, frame) in frames {
            #expect(PlayerControlsView.chipNearest(playheadX: frame.midX, in: frames) == kind)
        }
    }

    @Test("midpoints between chips break toward the closer center")
    func betweenChips() {
        // Between audio (midX 310) and subtitles (midX 570), nearer subtitles.
        #expect(PlayerControlsView.chipNearest(playheadX: 500, in: frames) == .subtitles)
        // Between speed (midX 780) and chapters (midX 950), nearer speed.
        #expect(PlayerControlsView.chipNearest(playheadX: 820, in: frames) == .speed)
    }

    @Test("playhead at the track's far ends clamps to the outer chips")
    func trackEnds() {
        #expect(PlayerControlsView.chipNearest(playheadX: 0, in: frames) == .audio)
        #expect(PlayerControlsView.chipNearest(playheadX: 1920, in: frames) == .chapters)
    }

    @Test("no measured chips yields nil")
    func emptyFrames() {
        #expect(PlayerControlsView.chipNearest(playheadX: 500, in: [:]) == nil)
    }
}

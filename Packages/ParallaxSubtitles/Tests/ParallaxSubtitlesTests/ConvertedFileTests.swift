import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// SRT and WebVTT files, which carry no look of their own: the line, its markup and its
/// placement come through, drawn in the app's default style.
@Suite("Converted SRT and WebVTT")
struct ConvertedFileTests {

    @Test("an SRT or WebVTT file draws its line at the bottom center", arguments: ["sidecar.srt", "sidecar.vtt"])
    func sidecarDrawsBottomCenter(path: String) async throws {
        let drawn = try await drawing(of: path, at: 2)
        let ink = try #require(drawn.ink)

        #expect(try #require(drawn.pixels).opaque.count > 50)
        #expect(ink.midY > hdCanvas.height * 2 / 3)
        #expect(abs(ink.midX - hdCanvas.width / 2) < 4)
    }

    /// Simultaneous lines are separate events, which libass stacks only while none of them
    /// carries a `\pos`.
    @Test("two WebVTT cues at the same time stack instead of overlapping")
    func simultaneousCuesStack() async throws {
        let renderer = try await loaded("simultaneous.vtt")
        let single = try #require(try await renderer.drawing(at: 2).ink)
        let stacked = try #require(try await renderer.drawing(at: 6).ink)

        #expect(stacked.height > single.height * 1.6)
        #expect(stacked.maxY <= hdCanvas.height)
    }

    @Test("before any style arrives, a converted line draws white inside a black ring at the bottom center, at a height that follows the canvas")
    func defaultLook() async throws {
        let drawn = try await drawing(of: "sidecar.srt", at: 2)
        let pixels = try #require(drawn.pixels)
        let ink = try #require(drawn.ink)

        #expect(pixels.opaque.contains { $0.red > 240 && $0.green > 240 && $0.blue > 240 })
        #expect(pixels.opaque.contains { $0.red < 10 && $0.green < 10 && $0.blue < 10 })
        #expect(!pixels.opaque.contains { max($0.red, $0.green, $0.blue) - min($0.red, $0.green, $0.blue) > 8 })
        #expect(ink.minY > hdCanvas.height * 2 / 3)
        #expect(abs(ink.midX - hdCanvas.width / 2) < 4)

        let half = try #require(try await drawing(of: "sidecar.srt", at: 2, canvas: CGSize(width: 640, height: 360)).ink)
        #expect(abs(ink.height / half.height - 2) < 0.1, "\(ink.height) at 720 lines, \(half.height) at 360")
    }

    /// `markup.srt`, a cue a second: Hi, <i>Hi</i>, <I>Hi</I>, <b>Hi</b>, <u>Hi</u>,
    /// <ruby>Hi</ruby><br/>There, HiThere, 2 < 3, 2 3.
    @Test("SRT italic, bold and underline tags change how the text draws, uppercase tags draw like lowercase, unknown tags draw as the bare text, and a lone < draws as text")
    func srtMarkup() async throws {
        let renderer = try await loaded("markup.srt")
        let cues = try await (1...9).asyncMap { try await renderer.drawing(at: Double($0) + 0.5) }
        let (plain, italic, upperItalic, bold, underline, unknownTags, bare, lessThan, withoutLessThan) =
            (cues[0], cues[1], cues[2], cues[3], cues[4], cues[5], cues[6], cues[7], cues[8])
        let plainInk = try #require(plain.ink)

        #expect(italic != plain)
        #expect(abs(try #require(italic.ink).height - plainInk.height) <= 2, "italic is not a size change")
        #expect(upperItalic == italic)
        #expect(Double(bold.fillCount) > Double(plain.fillCount) * 1.1)
        #expect(try #require(underline.ink).maxY > plainInk.maxY + 2)
        #expect(abs(try #require(underline.ink).minY - plainInk.minY) <= 1)
        #expect(unknownTags == bare)
        #expect(try #require(lessThan.ink).width > (try #require(withoutLessThan.ink).width) + 15)
    }

    /// `colors.srt`, a cue a second: Hi, then Hi inside a font tag colored #FF0000, yellow,
    /// 00FF00 (uppercase tag, no quotes, no #), #FF0000 with a bare Hi after it, #FF0000 around
    /// Hi, a #0000FF Hi and a third Hi, a tag with a face and a size only, the color
    /// "nonsense", and '#08f'.
    @Test("an SRT font tag colors its text in the hex or named color it gives, the closing tag gives back the color from before it, and a tag with no color it can read draws as the bare text")
    func srtFontColors() async throws {
        let renderer = try await loaded("colors.srt")
        let cues = try await (1...9).asyncMap { try await renderer.drawing(at: Double($0) + 0.5) }
        let plain = try #require(cues[0].ink)

        #expect(cues[0].box(ofColor: (255, 255, 255)) != nil)
        for (cue, color) in [(1, (255, 0, 0)), (2, (255, 255, 0)), (3, (0, 255, 0)), (8, (0, 136, 255))] {
            #expect(cues[cue].box(ofColor: color) != nil, "cue \(cue + 1) has no ink of \(color)")
            #expect(cues[cue].box(ofColor: (255, 255, 255)) == nil, "cue \(cue + 1) still has white ink")
            #expect(cues[cue].ink == plain, "cue \(cue + 1) moved or changed size")
        }
        let red = try #require(cues[4].box(ofColor: (255, 0, 0)))
        let white = try #require(cues[4].box(ofColor: (255, 255, 255)))
        #expect(white.minX > red.maxX, "the Hi after the closing tag: red \(red), white \(white)")
        let outer = try #require(cues[5].box(ofColor: (255, 0, 0)))
        let inner = try #require(cues[5].box(ofColor: (0, 0, 255)))
        #expect(outer.minX < inner.minX && outer.maxX > inner.maxX, "red \(outer) around blue \(inner)")
        #expect(cues[5].box(ofColor: (255, 255, 255)) == nil)
        #expect(cues[6] == cues[0], "a face and a size")
        #expect(cues[7] == cues[0], "an unknown color")
    }

    @Test("a text color picked in Settings colors the text its author left uncolored, and a colored span keeps its own color")
    func settingsColorLeavesAuthoredColors() async throws {
        let cyan = SubtitleStyleOverride(primaryColor: SubtitleColor(red: 0, green: 1, blue: 1))
        let drawn = try await drawing(of: "colors.srt", at: 5.5, style: cyan)

        let authored = try #require(drawn.box(ofColor: (255, 0, 0)))
        let picked = try #require(drawn.box(ofColor: (0, 255, 255)))
        #expect(picked.minX > authored.maxX, "red \(authored), cyan \(picked)")
        #expect(drawn.box(ofColor: (255, 255, 255)) == nil)
    }

    /// `colors.vtt`, a cue a second: Hi, then Hi in the classes yellow, red.bg_blue, warn
    /// (#000080 and then #ff8800 in the STYLE block), note (rgb(0, 128, 255) there), yellow with a bare Hi after
    /// it, unknown, none, and lime, which the STYLE block gives #800080.
    @Test("a WebVTT class span draws in the color its class names, one of the standard color classes or the last color the file's STYLE block gives the class, and a class with no color draws as the bare text")
    func webVTTClassColors() async throws {
        let renderer = try await loaded("colors.vtt")
        let cues = try await (1...9).asyncMap { try await renderer.drawing(at: Double($0) + 0.5) }
        let plain = try #require(cues[0].ink)

        for (cue, color) in [(1, (255, 255, 0)), (2, (255, 0, 0)), (3, (255, 136, 0)), (4, (0, 128, 255)), (8, (128, 0, 128))] {
            #expect(cues[cue].box(ofColor: color) != nil, "cue \(cue + 1) has no ink of \(color)")
            #expect(cues[cue].box(ofColor: (255, 255, 255)) == nil, "cue \(cue + 1) still has white ink")
            #expect(cues[cue].ink == plain, "cue \(cue + 1) moved or changed size")
        }
        let yellow = try #require(cues[5].box(ofColor: (255, 255, 0)))
        let white = try #require(cues[5].box(ofColor: (255, 255, 255)))
        #expect(white.minX > yellow.maxX, "the Hi after the closing tag: yellow \(yellow), white \(white)")
        #expect(cues[6] == cues[0], "a class with no color")
        #expect(cues[7] == cues[0], "no class")
    }

    @Test("an SRT line carrying {\\an8} or {\\a6} draws at the top of the screen", arguments: [
        (1, true), (2, true), (3, true), (4, false),
    ])
    func srtAlignmentTags(second: Int, top: Bool) async throws {
        let ink = try #require(try await drawing(of: "alignment.srt", at: Double(second) + 0.5).ink)

        #expect((ink.midY < hdCanvas.height / 3) == top, "cue \(second) drew at \(ink)")
    }

    enum Placement: Sendable, CustomStringConvertible {
        /// Exactly where a cue with no settings draws.
        case unplaced
        /// The ink's left, center or right edge at `x`, and its top, middle or bottom at `y`.
        case anchored(horizontal: Edge, x: Double, vertical: Edge, y: Double)

        enum Edge: Sendable { case start, middle, end }

        var description: String {
            switch self {
            case .unplaced: "unplaced"
            case let .anchored(h, x, v, y): "\(h) at \(x), \(v) at \(y)"
            }
        }
    }

    /// `placement.vtt` holds one "Hi" cue a second, one per settings string, in this order. A
    /// converted script is 1280x720, the size of the canvas here, with 40-unit side and
    /// 36-unit vertical margins.
    @Test("a WebVTT cue draws where its line, position and align settings put it, and a malformed setting leaves it at the bottom center", arguments: [
        (1, "", Placement.unplaced),
        (2, "align:start", .anchored(horizontal: .start, x: 40, vertical: .end, y: 684)),
        (3, "align:end", .anchored(horizontal: .end, x: 1240, vertical: .end, y: 684)),
        (4, "align:right", .anchored(horizontal: .end, x: 1240, vertical: .end, y: 684)),
        (5, "line:5%", .anchored(horizontal: .middle, x: 640, vertical: .start, y: 36)),
        (6, "line:50%", .anchored(horizontal: .middle, x: 640, vertical: .middle, y: 360)),
        (7, "line:90%", .anchored(horizontal: .middle, x: 640, vertical: .end, y: 648)),
        (8, "line:0", .anchored(horizontal: .middle, x: 640, vertical: .start, y: 36)),
        (9, "line:-1", .unplaced),
        (10, "position:25%", .anchored(horizontal: .middle, x: 320, vertical: .end, y: 684)),
        (11, "line:10% position:80%", .anchored(horizontal: .middle, x: 1024, vertical: .start, y: 72)),
        (12, "line:5% align:start", .anchored(horizontal: .start, x: 40, vertical: .start, y: 36)),
        (13, "line:90%,end", .anchored(horizontal: .middle, x: 640, vertical: .end, y: 648)),
        (14, "vertical:rl size:50%", .unplaced),
        (15, "align:", .unplaced),
        (16, "line:,end", .unplaced),
        (17, "position:nan%", .unplaced),
        (18, "line:1e999%", .unplaced),
        (19, "align:left", .anchored(horizontal: .start, x: 40, vertical: .end, y: 684)),
    ])
    func webVTTPlacement(second: Int, settings: String, placement: Placement) async throws {
        let drawn = try await drawing(of: "placement.vtt", at: Double(second) + 0.5)

        switch placement {
        case .unplaced:
            #expect(drawn == (try await drawing(of: "placement.vtt", at: 1.5)), "\(settings) moved the cue")
        case let .anchored(horizontal, x, vertical, y):
            let ink = try #require(drawn.ink)
            let inkX = switch horizontal { case .start: ink.minX; case .middle: ink.midX; case .end: ink.maxX }
            let inkY = switch vertical { case .start: ink.minY; case .middle: ink.midY; case .end: ink.maxY }
            // Half a line: the ink sits inside the line box the anchor names, short of its edge.
            #expect(abs(inkX - x) < 24 && abs(inkY - y) < 24, "\(settings) drew at \(ink), wanted \(placement)")
        }
    }

    /// `payload.vtt`, a cue a second: Hello there, <v Bob>Hello there</v>,
    /// Hello<00:00:03.500> there, <i>Hello there</i>, <ruby>漢<rt>かん</rt></ruby>, 漢かん.
    @Test("WebVTT voice, timestamp and ruby tags draw as the bare text, and <i> draws italic")
    func webVTTPayload() async throws {
        let renderer = try await loaded("payload.vtt")
        let cues = try await (1...6).asyncMap { try await renderer.drawing(at: Double($0) + 0.5) }

        #expect(cues[1] == cues[0], "voice tag")
        #expect(cues[2] == cues[0], "timestamp tag")
        #expect(cues[3] != cues[0], "italic")
        #expect(abs(try #require(cues[3].ink).height - (try #require(cues[0].ink).height)) <= 2, "italic is not a size change")
        #expect(cues[4] == cues[5], "ruby")
    }

    /// Jellyfin's cue times are already absolute; applying the header's MPEGTS offset would
    /// move every line ten seconds late (jellyfin#16647).
    @Test("a Jellyfin WebVTT file with an X-TIMESTAMP-MAP header draws each line at its own time")
    func timestampMapLeavesTimesAlone() async throws {
        let renderer = try await loaded("jellyfin-timestamp-map.vtt")

        #expect(try await renderer.drawing(at: 31).isBlank == false)
        #expect(try await renderer.drawing(at: 41).isBlank)
        #expect(try await renderer.drawing(at: 61).isBlank == false)
    }

    /// `escapes.srt`, a cue a second: Big, {\fs40}Big, a b c, a {b} c, CNew, C:\New, \喵/, and
    /// \ U+E000 /, the missing-glyph box in 喵's place.
    @Test("a brace or backslash in an SRT line draws as text and is never read as a tag")
    func bracesAndBackslashesAreText() async throws {
        let renderer = try await loaded("escapes.srt")
        let cues = try await (1...8).asyncMap { try await renderer.drawing(at: Double($0) + 0.5) }
        let inks = try cues.map { try #require($0.ink) }

        #expect(abs(inks[1].height - inks[0].height) <= 2, "{\\fs40} changed the size")
        #expect(inks[1].width > inks[0].width * 2, "{\\fs40} is not drawn")
        #expect(inks[3].width > inks[2].width + 10, "the braces are not drawn")
        #expect(abs(inks[5].height - inks[4].height) <= 2, "\\N broke the line")
        #expect(inks[5].width > inks[4].width + 10, "the backslash is not drawn")
        #expect(cues[6] != cues[7], "喵 after a backslash draws the missing-glyph box")
    }

    /// An SRT `</b>` becomes a bare `\b`, which libass reads as the style's own weight, the
    /// serif design's bold here, where a `\b0` would lighten the rest of the line.
    @Test("closing an SRT bold span keeps the serif design's weight on the rest of the line")
    func closingBoldKeepsTheWeight() async throws {
        let renderer = try await loaded(
            "bold.srt", languageHint: "ja", fontFamily: SubtitleFontBundle.serifCueFamily,
            style: SubtitleStyleOverride(bold: true)
        )
        let half = try await renderer.drawing(at: 1.5).fillCount
        let unmarked = try await renderer.drawing(at: 3.5).fillCount
        let closedHalfway = try await renderer.drawing(at: 4.5).fillCount

        #expect(unmarked > half)
        #expect(abs(closedHalfway - unmarked) <= unmarked / 33, "closed halfway \(closedHalfway), unmarked \(unmarked)")
    }
}

extension Drawing {
    /// The canvas box of the solid ink within a few levels of `color`.
    func box(ofColor color: (red: Int, green: Int, blue: Int)) -> CGRect? {
        box {
            $0.alpha > 250 && abs(Int($0.red) - color.red) <= 6 && abs(Int($0.green) - color.green) <= 6
                && abs(Int($0.blue) - color.blue) <= 6
        }
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}

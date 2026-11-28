import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// The subtitle style a user picks, laid over a file's own.
@Suite("Style override")
struct StyleOverrideTests {
    private static let probeCanvas = CGSize(width: 640, height: 360)

    @Test("a color style repaints a line, and removing it restores the authored color")
    func colorStyleRepaints() async throws {
        let renderer = try await loaded("colors.ass", canvas: Self.probeCanvas)
        #expect(try await renderer.drawing(at: 1.5).pixels?.dominantChannel == .red)

        await renderer.setStyle(SubtitleStyleOverride(primaryColor: SubtitleColor(red: 0, green: 1, blue: 0)))
        #expect(try await renderer.drawing(at: 1.5).pixels?.dominantChannel == .green)

        await renderer.setStyle(nil)
        #expect(try await renderer.drawing(at: 1.5).pixels?.dominantChannel == .red)
    }

    /// libass keeps the override style's `Name` pointer rather than a copy, so this is the
    /// shape that exposes a lifetime mistake under the address sanitizer.
    @Test("changing the subtitle style twelve times in a row keeps the line on screen")
    func repeatedStyleChanges() async throws {
        let renderer = try await loaded("hello.ass", canvas: Self.probeCanvas)

        for step in 0..<12 {
            await renderer.setStyle(step.isMultiple(of: 3) ? nil : SubtitleStyleOverride(
                fontFamily: step.isMultiple(of: 2) ? SubtitleFontBundle.serifFamily : SubtitleFontBundle.sansFamily,
                fontScale: 1 + Double(step) / 10,
                primaryColor: SubtitleColor(red: Double(step) / 12, green: 1, blue: 0)
            ))
            #expect(try await renderer.drawing(at: 1.5).isBlank == false, "step \(step)")
        }
    }

    @Test("the opaque box style paints a solid box behind the line")
    func opaqueBox() async throws {
        let renderer = try await loaded("hello.ass", canvas: Self.probeCanvas)
        let plain = try await renderer.drawing(at: 3.5)
        await renderer.setStyle(SubtitleStyleOverride(opaqueBox: true))
        let boxed = try await renderer.drawing(at: 3.5)

        let plainRect = plain.frame.imageRect
        let boxedRect = boxed.frame.imageRect
        #expect(boxedRect.minX < plainRect.minX && boxedRect.maxX > plainRect.maxX)
        #expect(boxedRect.minY < plainRect.minY && boxedRect.maxY > plainRect.maxY)

        let aboveTheGlyphs = (x: Int(plainRect.midX), y: Int(plainRect.minY) - 3)
        #expect(plain.pixel(x: aboveTheGlyphs.x, y: aboveTheGlyphs.y).alpha == 0)
        #expect(boxed.pixel(x: aboveTheGlyphs.x, y: aboveTheGlyphs.y).alpha > 250)

        #expect(try #require(boxed.opaqueFraction) > 0.55)
        #expect(try #require(plain.opaqueFraction) < 0.25)
    }

    /// The measured width carries a near-constant antialiasing fringe, a larger share of a
    /// smaller glyph, hence the tolerance.
    @Test("a size setting scales the text width in proportion, and removing it restores the authored width")
    func sizeScalesWidth() async throws {
        let renderer = try await loaded("hello.ass", canvas: Self.probeCanvas)
        let authoredDrawing = try await renderer.drawing(at: 2.5)
        let authored = try #require(authoredDrawing.ink).width

        var widths: [Double] = []
        for scale in [0.6, 0.7, 0.8, 2] {
            await renderer.setStyle(SubtitleStyleOverride(fontScale: scale))
            let width = try #require(try await renderer.drawing(at: 2.5).ink).width
            #expect(abs(width / authored - scale) < 0.05, "scale \(scale) drew \(width / authored) of the width")
            widths.append(width)
        }
        #expect(widths == widths.sorted() && Set(widths).count == widths.count, "\(widths)")

        await renderer.setStyle(nil)
        #expect(try await renderer.drawing(at: 2.5) == authoredDrawing)
    }

    @Test("a bold-only style thickens an authored line and keeps its colors")
    func boldOnlyKeepsColors() async throws {
        let renderer = try await loaded("colors.ass", canvas: Self.probeCanvas)
        let plain = try #require(try await renderer.drawing(at: 4.5).pixels)
        await renderer.setStyle(SubtitleStyleOverride(bold: true))
        let bold = try #require(try await renderer.drawing(at: 4.5).pixels)

        let isRedFill = { (pixel: RenderedPixels.Pixel) in pixel.alpha > 200 && pixel.red > 200 && pixel.blue < 60 }
        let isBlueRing = { (pixel: RenderedPixels.Pixel) in pixel.alpha > 200 && pixel.blue > 200 && pixel.red < 60 }
        #expect(bold.all.contains(where: isBlueRing))
        #expect(!bold.all.contains { $0.alpha > 200 && $0.green > 200 })
        #expect(Double(bold.all.count(where: isRedFill)) > Double(plain.all.count(where: isRedFill)) * 1.1)
    }

    /// No system font is reachable: a family the bundle lacks, even one installed on every
    /// Apple device, falls to the bundled default.
    @Test("a style naming a system font draws in the bundled Noto Sans")
    func systemFontDrawsNotoSans() async throws {
        let systemFont = try await drawing(of: "sidecar.srt", at: 2, style: SubtitleStyleOverride(fontFamily: "PingFang SC"))
        let bundled = try await drawing(of: "sidecar.srt", at: 2)

        #expect(systemFont == bundled)
    }
}

extension Drawing {
    /// Share of the drawn rect that is near-fully opaque.
    var opaqueFraction: Double? {
        pixels.map { Double($0.opaque.count) / Double($0.width * $0.height) }
    }
}

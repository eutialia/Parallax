import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// The ring around a converted line, read off the pixels: one opaque black band of the same
/// width on every side, ending abruptly, around a crisp fill. This is what catches the ring
/// turning back into a shadow or a blur.
@Suite("Outline ring")
struct OutlineRingTests {

    /// One tall stem at four times the size, so the bands are wide enough in whole pixels to
    /// measure.
    private func stem() async throws -> RenderedPixels {
        let style = SubtitleStyleOverride(
            fontScale: 4, primaryColor: SubtitleColor(red: 0.92, green: 0.92, blue: 0.92), opaqueBox: false
        )
        return try #require(try await drawing(of: "stem.srt", at: 2, style: style).pixels)
    }

    private func bands(_ pixels: RenderedPixels) throws -> [(String, [UInt8])] {
        let stem = try #require(pixels.stem)
        return [
            ("left", pixels.outlineBand(from: stem.left, dx: -1, dy: 0)),
            ("right", pixels.outlineBand(from: stem.right, dx: 1, dy: 0)),
            ("above", pixels.outlineBand(from: stem.top, dx: 0, dy: -1)),
            ("below", pixels.outlineBand(from: stem.bottom, dx: 0, dy: 1)),
        ]
    }

    /// Above and below are compared exactly: a drop shadow is displaced, a ring never is.
    @Test("the ring is the same width on all four sides")
    func ringIsUniform() async throws {
        let measured = try bands(try await stem()).map { ($0.0, $0.1.count) }
        let widths = measured.map(\.1)

        #expect(widths.min() ?? 0 >= 4, "the ring is too thin to measure: \(measured)")
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1, "the ring is not uniform: \(measured)")
        let width = Dictionary(uniqueKeysWithValues: measured)
        #expect(width["above"] == width["below"], "the ring is offset: \(width)")
    }

    @Test("the ring's outer edge is hard, not a falloff")
    func ringEdgeIsHard() async throws {
        for (name, band) in try bands(try await stem()) {
            let solidEnd = try #require(band.lastIndex { $0 >= 230 }, "\(name): \(band)")
            let fadeStart = band[solidEnd...].firstIndex { $0 < 26 } ?? band.count
            #expect(fadeStart - solidEnd - 1 <= 2, "\(name) takes \(fadeStart - solidEnd - 1)px to fade out: \(band)")
        }
    }

    @Test("the ring is opaque black right against the fill")
    func ringIsOpaque() async throws {
        for (name, band) in try bands(try await stem()) {
            #expect(band.first ?? 0 >= 242, "\(name) starts at \(band.first ?? 0)/255")
        }
    }

    /// Antialiasing is one pixel of partial coverage; a blurred fill takes the whole blur
    /// radius to get from the ring to the glyph.
    @Test("the fill keeps a crisp edge on every side")
    func fillEdgeStaysCrisp() async throws {
        let pixels = try await stem()
        let stem = try #require(pixels.stem)

        #expect(pixels.partialFillPixels(from: stem.left, dx: -1, dy: 0) <= 2)
        #expect(pixels.partialFillPixels(from: stem.right, dx: 1, dy: 0) <= 2)
        #expect(pixels.partialFillPixels(from: stem.top, dx: 0, dy: -1) <= 2)
        #expect(pixels.partialFillPixels(from: stem.bottom, dx: 0, dy: 1) <= 2)
    }

    /// Measured off the pixels: `imageRect` is padded for libass' SIMD blitters and
    /// quantizes by up to 16 px, too coarse for a border of a few.
    private func ink(outlineUnits: Double, videoHeight: CGFloat = 720, fontScale: Double = 1) async throws -> CGRect {
        let em = SubtitleRenderer.convertedScriptFontFraction * SubtitleRenderer.convertedScriptPlayRes.height
        let renderer = try await loaded(
            "border.srt",
            style: SubtitleStyleOverride(
                fontScale: fontScale, primaryColor: SubtitleColor(red: 1, green: 1, blue: 1), opaqueBox: false,
                outlineEmRatio: outlineUnits / em
            ),
            storage: CGSize(width: videoHeight * 16 / 9, height: videoHeight)
        )
        return try #require(try await renderer.drawing(at: 2).ink, "nothing was inked")
    }

    /// libass scales the outline by the factor it scales the glyphs by, so a ring set as a
    /// fraction of the em stays that fraction at every size.
    @Test("the ring stays the same fraction of the text at every size setting")
    func ringFollowsTheSize() async throws {
        let width = try await ink(outlineUnits: 10).maxX - (try await ink(outlineUnits: 0).maxX)
        let widthBig = try await ink(outlineUnits: 10, fontScale: 2).maxX - (try await ink(outlineUnits: 0, fontScale: 2).maxX)

        #expect(width > 6, "the ring has to be measurable first: \(width)")
        #expect(widthBig > width * 1.5 && widthBig < width * 2.5, "2x text drew a \(widthBig)px ring against \(width)px")
    }

    @Test("the ring is the same over a 360-line video and a 4K one", arguments: [360.0, 2160.0])
    func ringIgnoresTheVideoSize(videoHeight: CGFloat) async throws {
        let bare = try await ink(outlineUnits: 0)
        let reference = try await ink(outlineUnits: 10)
        let other = try await ink(outlineUnits: 10, videoHeight: videoHeight)

        #expect(reference.width - bare.width > 12, "there has to be a ring to hold still")
        #expect(abs(other.width - reference.width) <= 2)
        #expect(abs(other.height - reference.height) <= 2)
    }
}

// MARK: - Measurement

private extension RenderedPixels {

    func isFill(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return Self.isFill(self[x, y])
    }

    func isPartialFill(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return (40...200).contains(Int(self[x, y].red))
    }

    /// The four edge midpoints of the fill in the frame: top and bottom from its
    /// bounding box, left and right from the row halfway down — the stem of an
    /// "I", clear of its serifs.
    var stem: (left: (x: Int, y: Int), right: (x: Int, y: Int),
               top: (x: Int, y: Int), bottom: (x: Int, y: Int))? {
        guard let fill = bounds(where: isFill) else { return nil }
        let midY = (fill.minY + fill.maxY) / 2
        let row = (0..<width).filter { isFill($0, midY) }
        guard let left = row.first, let right = row.last else { return nil }
        let midX = (left + right) / 2
        return (
            left: (left, midY), right: (right, midY),
            top: (midX, fill.minY), bottom: (midX, fill.maxY)
        )
    }

    /// Ring alpha stepping away from a fill edge, past the glyph's own
    /// antialiasing and stopping where the ring does. Black-only: a pixel the
    /// glyph still tints is not part of the band.
    func outlineBand(from edge: (x: Int, y: Int), dx: Int, dy: Int) -> [UInt8] {
        var band: [UInt8] = []
        var x = edge.x + dx, y = edge.y + dy
        while x >= 0, x < width, y >= 0, y < height {
            let pixel = self[x, y]
            if pixel.red >= 40 {
                guard band.isEmpty else { break }   // still inside the fill's fringe
            } else {
                if pixel.alpha < 3 { break }
                band.append(pixel.alpha)
            }
            x += dx
            y += dy
        }
        return band
    }

    /// How many pixels the fill takes to go from absent to solid — one, plus the
    /// antialiasing, unless a blur landed on the glyph.
    func partialFillPixels(from edge: (x: Int, y: Int), dx: Int, dy: Int) -> Int {
        var count = 0
        var x = edge.x + dx, y = edge.y + dy
        while x >= 0, x < width, y >= 0, y < height, isPartialFill(x, y) {
            count += 1
            x += dx
            y += dy
        }
        return count
    }
}

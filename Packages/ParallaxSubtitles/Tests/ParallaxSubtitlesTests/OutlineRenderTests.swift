import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// The canonical plain-text look, asserted on the pixels libass produced: a crisp
/// glyph inside ONE opaque black ring, with no blur and no offset anywhere.
///
/// This is the suite that catches the ring turning back into a shadow. Every
/// property below is one the eye reads instantly and the Swift side cannot see:
/// the band is the same width on all four sides, it ends abruptly instead of
/// fading, and it is fully black rather than a tinted haze.
@Suite("Outline rendering")
struct OutlineRenderTests {

    /// A single tall stem at 4× the tuned size, on a 1:1 720-line canvas: the
    /// bands are then wide enough in whole pixels to measure.
    private static let scale = 4.0

    private static func override() -> SubtitleStyleOverride {
        SubtitleStyleOverride(
            fontScale: scale,
            primaryColor: SubtitleColor(red: 0.92, green: 0.92, blue: 0.92),
            opaqueBox: false,
            outlineEmRatio: SubtitleRenderer.convertedScriptOutlineEmRatio
        )
    }

    private func renderStem() async throws -> RenderedPixels {
        let renderer = SubtitleRenderer()
        await renderer.setCanvas(
            size: CGSize(width: 1280, height: 720), scale: 1,
            storageSize: CGSize(width: 1280, height: 720)
        )
        try await renderer.load(SRTFixture.data(text: "I"), format: .srt)
        await renderer.setStyleOverride(Self.override())
        let frame = try #require(await renderer.frame(at: 2.0))
        return try rendered(try #require(frame.image))
    }

    private func bands(
        _ pixels: RenderedPixels,
        _ stem: (left: (x: Int, y: Int), right: (x: Int, y: Int),
                 top: (x: Int, y: Int), bottom: (x: Int, y: Int))
    ) -> [(String, [UInt8])] {
        [
            ("left", pixels.outlineBand(from: stem.left, dx: -1, dy: 0)),
            ("right", pixels.outlineBand(from: stem.right, dx: 1, dy: 0)),
            ("above", pixels.outlineBand(from: stem.top, dx: 0, dy: -1)),
            ("below", pixels.outlineBand(from: stem.bottom, dx: 0, dy: 1)),
        ]
    }

    // MARK: - Assertions

    @Test("the ring is the same width on all four sides")
    func ringIsUniform() async throws {
        let pixels = try await renderStem()
        let measured = bands(pixels, try #require(pixels.stem))
        let widths = measured.map(\.1.count)

        #expect(widths.min() ?? 0 >= 4, "the ring is too thin to measure: \(measured)")
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1,
                "the ring is not uniform: \(measured.map { ($0.0, $0.1.count) })")
    }

    /// A ring ends where the stroke ends. Anything that takes more than the
    /// antialiasing to reach transparency is a blur wearing a ring's name.
    @Test("the ring's outer edge is hard, not a falloff")
    func ringEdgeIsHard() async throws {
        let pixels = try await renderStem()
        for (name, band) in bands(pixels, try #require(pixels.stem)) {
            let solidEnd = try #require(band.lastIndex { $0 >= 230 }, "\(name): \(band)")
            let fadeStart = band[solidEnd...].firstIndex { $0 < 26 } ?? band.count
            #expect(fadeStart - solidEnd - 1 <= 2,
                    "\(name) takes \(fadeStart - solidEnd - 1)px to fade out: \(band)")
        }
    }

    @Test("the ring is opaque black right against the fill")
    func ringIsOpaque() async throws {
        let pixels = try await renderStem()
        for (name, band) in bands(pixels, try #require(pixels.stem)) {
            #expect(band.first ?? 0 >= 242, "\(name) starts at \(band.first ?? 0)/255")
        }
    }

    @Test("the fill keeps a crisp edge on every side")
    func fillEdgeStaysCrisp() async throws {
        let pixels = try await renderStem()
        let stem = try #require(pixels.stem)

        // Antialiasing is one pixel of partial coverage; a blurred fill would take
        // the whole blur radius to get from the ring to the glyph.
        #expect(pixels.partialFillPixels(from: stem.left, dx: -1, dy: 0) <= 2)
        #expect(pixels.partialFillPixels(from: stem.right, dx: 1, dy: 0) <= 2)
        #expect(pixels.partialFillPixels(from: stem.top, dx: 0, dy: -1) <= 2)
        #expect(pixels.partialFillPixels(from: stem.bottom, dx: 0, dy: 1) <= 2)
    }

    /// The one property a drop shadow can never have, and the reason the old look
    /// is gone: nothing is displaced, so the band above the cap is the band below
    /// the baseline.
    @Test("nothing is offset: the band above the stem matches the band below")
    func ringIsNotOffset() async throws {
        let pixels = try await renderStem()
        let stem = try #require(pixels.stem)

        let above = pixels.outlineBand(from: stem.top, dx: 0, dy: -1)
        let below = pixels.outlineBand(from: stem.bottom, dx: 0, dy: 1)
        #expect(below.count >= 4, "no band to compare: below is \(below.count)px")
        #expect(above.count == below.count,
                "above reaches \(above.count)px, below \(below.count)px")
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

import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// The canonical plain-text look, asserted on the pixels libass produced: a crisp
/// glyph over ONE soft drop shadow, and no ring.
///
/// This is the suite that catches the way the blur is delivered breaking. libass
/// blurs a single bitmap per cue — the border's when there is one, the glyph's
/// otherwise — and copies it into the shadow, so the boxless look asks for a
/// transparent hair-thin border it never draws. Lose that and the blur moves onto
/// the text, which reads as a focus problem long before anyone calls it a bug.
@Suite("Soft shadow rendering")
struct SoftShadowRenderTests {

    /// A single tall stem at 4× the tuned size, on a 1:1 720-line canvas: the
    /// bands are then wide enough in whole pixels to measure.
    private static let scale = 4.0

    private static func override(blurRatio: Double = 0.05) -> SubtitleStyleOverride {
        SubtitleStyleOverride(
            fontScale: scale,
            primaryColor: SubtitleColor(red: 0.92, green: 0.92, blue: 0.92),
            opaqueBox: false,
            shadowEmRatio: 0.03,
            blurEmRatio: blurRatio,
            shadowAlpha: 0.80
        )
    }

    private func renderStem(
        override: SubtitleStyleOverride = SoftShadowRenderTests.override()
    ) async throws -> RenderedPixels {
        let renderer = SubtitleRenderer()
        await renderer.setCanvas(
            size: CGSize(width: 1280, height: 720), scale: 1,
            storageSize: CGSize(width: 1280, height: 720)
        )
        try await renderer.load(SRTFixture.data(text: "I"), format: .srt)
        await renderer.setStyleOverride(override)
        let frame = try #require(await renderer.frame(at: 2.0))
        return try rendered(try #require(frame.image))
    }

    // MARK: - Assertions

    @Test("the shadow falls off softly below and right of the stem")
    func softFalloffBelowRight() async throws {
        let pixels = try await renderStem()
        let stem = try #require(pixels.stem)

        let right = pixels.shadowBand(from: stem.right, dx: 1, dy: 0)
        let below = pixels.shadowBand(from: stem.bottom, dx: 0, dy: 1)

        for (name, band) in [("right", right), ("below", below)] {
            #expect(band.count >= 8, "\(name) band is \(band.count)px wide: \(band)")
            #expect(Set(band).count >= 5, "\(name) band has no gradient: \(band)")
            #expect(band.first ?? 0 > 90, "\(name) band starts at \(band.first ?? 0)")
            #expect(band.last ?? 255 < 20, "\(name) band ends at \(band.last ?? 255)")
            #expect(band.max() ?? 255 <= 210, "\(name) band peaks at \(band.max() ?? 255) — over 80% black")
            #expect(zip(band, band.dropFirst()).allSatisfy { $0 >= $1 - 2 },
                    "\(name) band is not a falloff: \(band)")
            #expect(band.longestFlatRun <= 4, "\(name) band has a flat plateau: \(band)")
        }
    }

    /// The offset is what makes it a shadow rather than a glow. A 5%-em blur with a
    /// 3%-em offset does reach up and left — the radius is wider than the offset —
    /// but it has to arrive there far weaker and die out sooner.
    @Test("nothing above and left reads as a second dark edge")
    func aboveLeftStaysFaint() async throws {
        let pixels = try await renderStem()
        let stem = try #require(pixels.stem)

        let left = pixels.shadowBand(from: stem.left, dx: -1, dy: 0)
        let right = pixels.shadowBand(from: stem.right, dx: 1, dy: 0)
        let above = pixels.shadowBand(from: stem.top, dx: 0, dy: -1)
        let below = pixels.shadowBand(from: stem.bottom, dx: 0, dy: 1)

        #expect(Double(left.max() ?? 0) < Double(right.max() ?? 0) * 0.7,
                "left peaks at \(left.max() ?? 0) against right's \(right.max() ?? 0)")
        #expect(Double(above.max() ?? 0) < Double(below.max() ?? 0) * 0.7,
                "above peaks at \(above.max() ?? 0) against below's \(below.max() ?? 0)")
        #expect(left.count < right.count, "left reaches \(left.count)px, right \(right.count)px")
        #expect(above.count < below.count, "above reaches \(above.count)px, below \(below.count)px")
    }

    @Test("the fill keeps a crisp edge on every side")
    func fillEdgeStaysCrisp() async throws {
        let pixels = try await renderStem()
        let stem = try #require(pixels.stem)

        // Antialiasing is one pixel of partial coverage; a blurred fill would take
        // the whole blur radius to get from the shadow to the glyph.
        #expect(pixels.partialFillPixels(from: stem.left, dx: -1, dy: 0) <= 2)
        #expect(pixels.partialFillPixels(from: stem.right, dx: 1, dy: 0) <= 2)
        #expect(pixels.partialFillPixels(from: stem.top, dx: 0, dy: -1) <= 2)
        #expect(pixels.partialFillPixels(from: stem.bottom, dx: 0, dy: 1) <= 2)
    }

    /// The control: the same cue with the blur switched off has the same fill and a
    /// hard-edged shadow, so a pass above cannot come from anything but the blur.
    @Test("without the blur the same shadow has a hard edge")
    func unblurredShadowIsHardEdged() async throws {
        let pixels = try await renderStem(override: Self.override(blurRatio: 0))
        let stem = try #require(pixels.stem)

        let right = pixels.shadowBand(from: stem.right, dx: 1, dy: 0)
        #expect(right.longestFlatRun >= 6, "an unblurred shadow should be flat: \(right)")
    }
}

private extension [UInt8] {
    /// The longest stretch of one value — a blur has none, a hard offset is all of it.
    var longestFlatRun: Int {
        var longest = 0, run = 0
        for (index, value) in enumerated() {
            run = index > 0 && self[index - 1] == value ? run + 1 : 1
            longest = Swift.max(longest, run)
        }
        return longest
    }
}

// MARK: - Measurement

private extension RenderedPixels {

    /// The white glyph fill: 92% white composited over the shadow, so the colour
    /// channels — not the alpha, which the shadow also raises — identify it.
    func isFill(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return self[x, y].red > 200
    }

    func isPartialFill(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return (40...200).contains(Int(self[x, y].red))
    }

    /// The four edge midpoints of the tallest run of fill in the frame — the stem
    /// of an "I", clear of its serifs.
    var stem: (left: (x: Int, y: Int), right: (x: Int, y: Int),
               top: (x: Int, y: Int), bottom: (x: Int, y: Int))? {
        var best: (x: Int, top: Int, bottom: Int)?
        for x in 0..<width {
            let column = (0..<height).filter { isFill(x, $0) }
            guard let top = column.first, let bottom = column.last else { continue }
            if bottom - top > (best.map { $0.bottom - $0.top } ?? 0) {
                best = (x, top, bottom)
            }
        }
        guard let best else { return nil }
        let midY = (best.top + best.bottom) / 2
        let row = (0..<width).filter { isFill($0, midY) }
        guard let left = row.first, let right = row.last else { return nil }
        let midX = (left + right) / 2
        return (
            left: (left, midY), right: (right, midY),
            top: (midX, best.top), bottom: (midX, best.bottom)
        )
    }

    /// Shadow alpha stepping away from a fill edge, past the glyph's own
    /// antialiasing and stopping where the shadow does. Black-only: a pixel the
    /// glyph still tints is not part of the band.
    func shadowBand(from edge: (x: Int, y: Int), dx: Int, dy: Int) -> [UInt8] {
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
    /// antialiasing, unless the blur landed on the glyph.
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

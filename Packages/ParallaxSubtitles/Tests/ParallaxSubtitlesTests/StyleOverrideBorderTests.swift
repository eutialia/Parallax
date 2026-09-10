import CoreGraphics
import Foundation
import Libass
import Testing

@testable import ParallaxSubtitles

/// The override's ring geometry must reach the rendered pixels: a field libass
/// never reads is invisible from the Swift side, because the fields only take
/// effect when their override bit is enabled.
///
/// Only CONVERTED scripts are overridden — an authored one keeps its creator's
/// borders — so the em every ratio resolves against is the synthesized script's,
/// and one script unit is `1/48` of an em.
@Suite("Style override borders")
struct StyleOverrideBorderTests {

    /// A field libass never reads is invisible, so `bold` has to bring its own
    /// bit — and bring only that one, or an unset colour would flatten the
    /// script's palette on the way past.
    @Test("bold enables the attributes bit and nothing else")
    func boldEnablesTheAttributesBit() {
        #expect(SubtitleStyleOverride(bold: nil).isNoOp)
        for bold in [true, false] {
            let override = SubtitleStyleOverride(bold: bold)
            #expect(override.isNoOp == false)
            #expect(override.overrideBits == Int32(ASS_OVERRIDE_BIT_ATTRIBUTES.rawValue))
        }
    }

    /// The bbox of everything libass actually inked, in canvas pixels.
    ///
    /// Measured off the pixels, not off `imageRect`: that rect is the union of
    /// libass' own bitmaps, whose widths are padded for its SIMD blitters, so it
    /// quantizes by up to 16px and cannot resolve a border of a few pixels.
    private func inkExtent(
        outlineUnits: Double, storageHeight: CGFloat = 720, fontScale: Double = 1
    ) async throws -> CGRect {
        let renderer = SubtitleRenderer()
        await renderer.setCanvas(
            size: CGSize(width: 1280, height: 720), scale: 1,
            storageSize: CGSize(width: storageHeight * 16 / 9, height: storageHeight)
        )
        try await renderer.load(SRTFixture.data(text: "Border"), format: .srt)
        await renderer.setStyleOverride(SubtitleStyleOverride(
            fontScale: fontScale,
            primaryColor: SubtitleColor(red: 1, green: 1, blue: 1),
            opaqueBox: false,
            outlineEmRatio: outlineUnits / Double(ASSScriptBuilder.fontSize)
        ))
        let frame = try #require(await renderer.frame(at: 2.0))
        let pixels = try rendered(try #require(frame.image))

        let ink = try #require(
            pixels.bounds { pixels[$0, $1].alpha >= 8 }, "nothing was inked"
        )
        return CGRect(
            x: frame.imageRect.minX + CGFloat(ink.minX),
            y: frame.imageRect.minY + CGFloat(ink.minY),
            width: CGFloat(ink.maxX - ink.minX + 1), height: CGFloat(ink.maxY - ink.minY + 1)
        )
    }

    /// A ring is symmetric by definition: it grows the ink by the same amount on
    /// every side, which is what tells it apart from an offset shadow.
    @Test("the ring grows the drawn extents equally on all four sides")
    func ringGrowsEverySideEqually() async throws {
        let bare = try await inkExtent(outlineUnits: 0)
        let ringed = try await inkExtent(outlineUnits: 10)

        let grew = [
            "left": bare.minX - ringed.minX, "right": ringed.maxX - bare.maxX,
            "top": bare.minY - ringed.minY, "bottom": ringed.maxY - bare.maxY,
        ]
        for (side, delta) in grew {
            #expect(delta > 6, "\(side) grew \(delta)px")
        }
        let spread = (grew.values.max() ?? 0) - (grew.values.min() ?? 0)
        #expect(spread <= 2, "the ring is not symmetric: \(grew)")
    }

    /// The whole reason `borderGeometry` resolves against the AUTHORED em and not
    /// the rendered one: libass scales Outline by the same factor it scales the
    /// glyphs, so a ratio of the em stays a ratio of the em at every size setting.
    /// Resolve it against the rendered size instead and the user's scale is applied
    /// twice — the ring goes fat at the small end and vanishes at the large one.
    @Test("the ring scales with the font, so it stays the same fraction of the em")
    func ringRidesTheFontScale() async throws {
        let bare = try await inkExtent(outlineUnits: 0)
        let ringed = try await inkExtent(outlineUnits: 10)
        let bareBig = try await inkExtent(outlineUnits: 0, fontScale: 2)
        let ringedBig = try await inkExtent(outlineUnits: 10, fontScale: 2)

        let width = ringed.maxX - bare.maxX
        let widthBig = ringedBig.maxX - bareBig.maxX
        #expect(width > 6, "the 1x ring has to be measurable first: \(width)")
        #expect(widthBig > width * 1.5 && widthBig < width * 2.5,
                "2x text drew a \(widthBig)px ring against \(width)px at 1x")
    }

    /// libass scales the override's Outline against the script's PlayRes, never the
    /// video's storage size — so the same cue over a 360-line source and a 4K one
    /// carries the same ring.
    @Test("the ring does not change with the video's native size",
          arguments: [360.0, 2160.0])
    func ringIsStorageIndependent(storageHeight: CGFloat) async throws {
        let bare = try await inkExtent(outlineUnits: 0)
        let reference = try await inkExtent(outlineUnits: 10)
        let other = try await inkExtent(outlineUnits: 10, storageHeight: storageHeight)

        #expect(reference.width - bare.width > 12, "there has to be a ring to hold still")
        #expect(abs(other.width - reference.width) <= 2)
        #expect(abs(other.height - reference.height) <= 2)
    }
}

import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// The override's border geometry must reach the rendered pixels: libass does
/// not scale borders with the font scale, so a silently ignored field brings
/// back the constant "heavy tint" the em-relative ratios exist to avoid.
///
/// Only CONVERTED scripts are overridden — an authored one keeps its creator's
/// borders — so the em every ratio resolves against is the synthesized script's.
@Suite("Style override borders")
struct StyleOverrideBorderTests {

    /// The em the fixtures' overrides describe: the synthesized script's own,
    /// so a ratio of 1/48 is one script unit on a 720-line canvas.
    private static let em = SubtitleRenderer.convertedScriptFontFraction

    private func inkExtent(outlineUnits: Double, shadowUnits: Double) async throws -> CGRect {
        let renderer = SubtitleRenderer()
        await renderer.setCanvas(
            size: CGSize(width: 1280, height: 720), scale: 1,
            storageSize: CGSize(width: 1280, height: 720)
        )
        try await renderer.load(SRTFixture.data(text: "Border"), format: .srt)
        await renderer.setStyleOverride(SubtitleStyleOverride(
            fontScale: 1,
            primaryColor: SubtitleColor(red: 1, green: 1, blue: 1),
            outlineColor: SubtitleColor(red: 0, green: 0, blue: 0),
            opaqueBox: false,
            emHeightRatio: Self.em,
            outlineEmRatio: outlineUnits / Double(ASSScriptBuilder.fontSize),
            shadowEmRatio: shadowUnits / Double(ASSScriptBuilder.fontSize)
        ))
        let frame = try #require(await renderer.frame(at: 2.0))
        return frame.imageRect
    }

    @Test("outline width and shadow offset change the drawn extents")
    func borderFieldsReachPixels() async throws {
        let thin = try await inkExtent(outlineUnits: 1, shadowUnits: 0)
        let thick = try await inkExtent(outlineUnits: 12, shadowUnits: 0)
        // A 12-unit border adds ~11 units per side over a 1-unit one.
        #expect(thick.width - thin.width > 16)
        #expect(thick.height - thin.height > 16)

        let shadowed = try await inkExtent(outlineUnits: 1, shadowUnits: 10)
        #expect(shadowed.height - thin.height > 6)
    }
}

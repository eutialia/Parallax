import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// The override's script-unit border/shadow fields must reach the rendered
/// pixels — libass does not scale borders with the font scale, so callers size
/// them proportionally and a silently ignored field brings back the constant
/// "heavy tint" this exists to fix.
@Suite("Style override borders")
struct StyleOverrideBorderTests {

    private func inkExtent(outlineWidth: Double, shadowOffset: Double) async throws -> CGRect {
        let renderer = SubtitleRenderer()
        await renderer.setCanvas(
            size: CGSize(width: 1280, height: 720), scale: 1,
            storageSize: CGSize(width: 1280, height: 720)
        )
        try await renderer.load(Data("1\n00:00:01,000 --> 00:00:03,000\nBorder\n".utf8), format: .srt)
        await renderer.setStyleOverride(SubtitleStyleOverride(
            fontScale: 1,
            primaryColor: SubtitleColor(red: 1, green: 1, blue: 1),
            outlineColor: SubtitleColor(red: 0, green: 0, blue: 0),
            opaqueBox: false,
            outlineWidth: outlineWidth,
            shadowOffset: shadowOffset
        ))
        let frame = try #require(await renderer.frame(at: 2.0))
        return frame.imageRect
    }

    @Test("outline width and shadow offset change the drawn extents")
    func borderFieldsReachPixels() async throws {
        let thin = try await inkExtent(outlineWidth: 1, shadowOffset: 0)
        let thick = try await inkExtent(outlineWidth: 12, shadowOffset: 0)
        // A 12-unit border adds ~11 units per side over a 1-unit one.
        #expect(thick.width - thin.width > 16)
        #expect(thick.height - thin.height > 16)

        let shadowed = try await inkExtent(outlineWidth: 1, shadowOffset: 10)
        #expect(shadowed.height - thin.height > 6)
    }
}

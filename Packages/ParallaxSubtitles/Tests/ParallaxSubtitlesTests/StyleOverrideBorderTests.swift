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

    // MARK: - The track's own canvas

    /// libass fills a missing dimension itself, but only at the first rendered
    /// frame and behind no accessor — so `SubtitleRenderer` mirrors the rule
    /// (`ass_lazy_track_init`, ass.c 0.17.5). Guessing 720 here is what an
    /// app-side header scanner did, and it is wrong for three of these four.
    @Test("the loaded track's effective PlayRes follows libass' own inference", arguments: [
        (1920, 1080, CGSize(width: 1920, height: 1080)),
        (1280, 0, CGSize(width: 1280, height: 1024)),
        (1920, 0, CGSize(width: 1920, height: 1440)),
        (0, 0, CGSize(width: 384, height: 288)),
        (0, 1024, CGSize(width: 1280, height: 1024)),
        (0, 720, CGSize(width: 960, height: 720)),
    ])
    func trackPlayResMirrorsLibass(playResX: Int, playResY: Int, expected: CGSize) async throws {
        #expect(ASSPlayRes.effective(x: playResX, y: playResY) == expected)

        // …and the same answer comes back out of a really loaded track. A
        // declared value of 0 is written as an omitted header, which is what a
        // script actually looks like.
        var script = ASSFixture.script(text: "Border", playResX: max(playResX, 1), playResY: max(playResY, 1))
        if playResX <= 0 { script = script.replacingOccurrences(of: "PlayResX: \(max(playResX, 1))\n", with: "") }
        if playResY <= 0 { script = script.replacingOccurrences(of: "PlayResY: \(max(playResY, 1))\n", with: "") }

        let renderer = await makeProbeRenderer()
        try await renderer.load(Data(script.utf8), format: .ass)
        #expect(await renderer.trackPlayRes == expected)
    }

    @Test("no track loaded means no PlayRes to report")
    func playResIsNilBeforeLoad() async {
        #expect(await SubtitleRenderer().trackPlayRes == nil)
    }
}

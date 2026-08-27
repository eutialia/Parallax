import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// The override's border geometry must reach the rendered pixels, and it must
/// land on the same pixels whatever canvas the script was authored against.
/// libass does not scale borders with the font scale, so a silently ignored
/// field brings back the constant "heavy tint" — and it DOES normalise them
/// across PlayRes, so the plausible-looking `* PlayResY / 720` correction the
/// app used to apply made a 1080p fansub's ring 1.5x heavier instead of equal.
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
            outlineEmRatio: outlineUnits / SubtitleRenderer.convertedScriptFontSize,
            shadowEmRatio: shadowUnits / SubtitleRenderer.convertedScriptFontSize
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

    /// The same "Use My Style" border setting on a 720p and a 1080p authored
    /// script has to put the same number of PIXELS of ring around the glyph.
    ///
    /// It does — as long as nobody rescales the value by PlayResY on the way in.
    /// Measured on this exact path: a script-unit `Outline` is resolution
    /// independent in libass, so the "obvious" `* PlayResY / 720` correction
    /// makes the 1080p script's ring 1.5x heavier instead of equal. That
    /// correction lived in the app for a while; this is the guard against it
    /// coming back.
    @Test("an authored border is the same thickness at 720p and 1080p")
    func authoredBorderIsResolutionIndependent() async throws {
        func inkExtent(playResY: Int) async throws -> CGRect {
            let renderer = SubtitleRenderer()
            await renderer.setCanvas(
                size: CGSize(width: 1280, height: 720), scale: 1,
                storageSize: CGSize(width: 1280, height: 720)
            )
            // Font size proportional to the canvas, so the glyphs themselves
            // render identically and only the ring is under test.
            try await renderer.load(
                ASSFixture.data(
                    text: "{\\an5}Border",
                    playResX: playResY * 16 / 9, playResY: playResY,
                    fontSize: 48 * playResY / 720
                ),
                format: .ass
            )
            await renderer.setStyleOverride(SubtitleStyleOverride(
                fontScale: 1,
                primaryColor: SubtitleColor(red: 1, green: 1, blue: 1),
                outlineColor: SubtitleColor(red: 0, green: 0, blue: 0),
                opaqueBox: false,
                emHeightRatio: Self.em,
                outlineEmRatio: 0.12,
                shadowEmRatio: 0
            ))
            return try #require(await renderer.frame(at: 2.0)).imageRect
        }

        let bare = try await { () async throws -> CGRect in
            let renderer = SubtitleRenderer()
            await renderer.setCanvas(
                size: CGSize(width: 1280, height: 720), scale: 1,
                storageSize: CGSize(width: 1280, height: 720)
            )
            try await renderer.load(
                ASSFixture.data(text: "{\\an5}Border", playResY: 720, fontSize: 48), format: .ass
            )
            return try #require(await renderer.frame(at: 2.0)).imageRect
        }()

        let hd = try await inkExtent(playResY: 720)
        let fullHD = try await inkExtent(playResY: 1080)
        #expect(abs(hd.width - fullHD.width) <= 1)
        #expect(abs(hd.height - fullHD.height) <= 1)
        // And the ring is actually drawn — equal-and-absent would pass above.
        #expect(hd.width > bare.width + 8)
    }

    // MARK: - The authored track's own em

    /// The ring one authored script draws, in pixels per side: the ink extent
    /// with the override's border, less the same script's bare ink.
    private func ringWidth(fontSize: Int, outlineEmRatio: Double?) async throws -> Double {
        func extent(_ ratio: Double?) async throws -> CGRect {
            let renderer = SubtitleRenderer()
            await renderer.setCanvas(
                size: CGSize(width: 1280, height: 720), scale: 1,
                storageSize: CGSize(width: 1280, height: 720)
            )
            try await renderer.load(
                ASSFixture.data(text: "{\\an5}Border", playResY: 720, fontSize: fontSize),
                format: .ass
            )
            // No override at all for the bare frame: the fixture authors
            // Outline 0, whereas an override with nil border fields would push
            // the renderer's own default outline and measure nothing.
            if let ratio {
                await renderer.setStyleOverride(SubtitleStyleOverride(
                    fontScale: 1,
                    primaryColor: SubtitleColor(red: 1, green: 1, blue: 1),
                    outlineColor: SubtitleColor(red: 0, green: 0, blue: 0),
                    opaqueBox: false,
                    emHeightRatio: Self.em,
                    outlineEmRatio: ratio,
                    shadowEmRatio: 0
                ))
            }
            return try #require(await renderer.frame(at: 2.0)).imageRect
        }
        let bare = try await extent(nil)
        let ringed = try await extent(outlineEmRatio)
        return (ringed.width - bare.width) / 2
    }

    /// "12% of the em" has to mean the em the AUTHOR wrote. Resolved against the
    /// synthesized script's 48/720 instead — which is what the renderer did for
    /// every track, converted or not — a `Fontsize: 20` fansub got a ring 2.4x
    /// heavier than its glyphs and a `Fontsize: 72` one a third of what it
    /// asked for.
    ///
    /// Asserted as an equivalence rather than a proportion, because the ink
    /// extent libass reports is not linear in the stroke width (a ring wide
    /// relative to its glyph saturates): the same ratio against a 3.6x larger
    /// Fontsize must produce the ring a 3.6x smaller ratio produces against the
    /// small one, and both must differ from applying the ratio unscaled.
    @Test("an authored ring is a fraction of the AUTHORED Fontsize")
    func authoredBorderFollowsTheAuthoredFontSize() async throws {
        let small = try await ringWidth(fontSize: 20, outlineEmRatio: 0.12)
        let equivalent = try await ringWidth(fontSize: 72, outlineEmRatio: 0.12 * 20 / 72)
        let unscaled = try await ringWidth(fontSize: 72, outlineEmRatio: 0.12)

        #expect(small > 4)
        #expect(abs(equivalent - small) <= 2, "\(small) vs \(equivalent)")
        // …and the Fontsize really is what moved it: the same ratio on the
        // large script draws a far heavier ring.
        #expect(unscaled > small * 3, "\(small) vs \(unscaled)")
    }
}

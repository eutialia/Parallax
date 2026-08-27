import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// These run the real libass on the simulator: they are the only proof that the
/// engine links against our own copy, finds fonts through CoreText, and that the
/// blend hands back pixels CoreGraphics can read.
@Suite("SubtitleRenderer")
struct SubtitleRendererTests {

    @Test("a cue renders opaque pixels while it is on screen, and clears afterwards")
    func rendersAndClears() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(ASSFixture.data(text: "Hello"), format: .ass)

        let midCue = try #require(await renderer.frame(at: 2))
        let image = try #require(midCue.image)
        #expect(midCue.canvasSize == CGSize(width: 640, height: 360))
        #expect(image.width > 0 && image.height > 0)
        #expect(try rendered(image).opaque.count > 100)

        // Past the cue the overlay must be told to clear, not merely left alone.
        let afterCue = try #require(await renderer.frame(at: 5))
        #expect(afterCue.image == nil)
        #expect(afterCue.isEmpty)
    }

    @Test("an unchanged timestamp reports no new frame")
    func changeDetection() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(ASSFixture.data(text: "Hello"), format: .ass)

        #expect(await renderer.frame(at: 2) != nil)
        // Same instant, same content: nothing for the caller to redraw.
        #expect(await renderer.frame(at: 2) == nil)
        // Moving to a different cue state produces a frame again.
        #expect(await renderer.frame(at: 5) != nil)
    }

    /// The permanent regression test for positioning. `\an` picks one of nine
    /// anchors; each has to land in its own third of the canvas.
    @Test("the nine ASS anchors land in the matching canvas cell", arguments: [
        ("bottom left", 1, 0, 2),
        ("bottom centre", 2, 1, 2),
        ("bottom right", 3, 2, 2),
        ("middle left", 4, 0, 1),
        ("middle centre", 5, 1, 1),
        ("middle right", 6, 2, 1),
        ("top left", 7, 0, 0),
        ("top centre", 8, 1, 0),
        ("top right", 9, 2, 0),
    ] as [(String, Int, Int, Int)])
    func anchorPlacement(label: String, anchor: Int, column: Int, row: Int) async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(ASSFixture.data(text: "{\\an\(anchor)}Probe"), format: .ass)

        let frame = try #require(await renderer.frame(at: 2))
        #expect(frame.image != nil, "\(label): nothing rendered")

        let cellWidth = CGFloat(ASSFixture.playResX) / 3
        let cellHeight = CGFloat(ASSFixture.playResY) / 3
        let actualColumn = Int(frame.imageRect.midX / cellWidth)
        let actualRow = Int(frame.imageRect.midY / cellHeight)
        #expect(actualColumn == column, "\(label): rect \(frame.imageRect) is in column \(actualColumn)")
        #expect(actualRow == row, "\(label): rect \(frame.imageRect) is in row \(actualRow)")
    }

    /// ASS colours are written BGR, so `&H0000FF&` is red. Sampling the blend
    /// output guards the channel order and the premultiply at the same time: a
    /// swapped order would read blue, a broken premultiply would read black.
    @Test("ASS BGR colour literals reach the blend in the right channels", arguments: [
        ("red", "&H000000FF", 0),
        ("green", "&H0000FF00", 1),
        ("blue", "&H00FF0000", 2),
    ] as [(String, String, Int)])
    func colorFidelity(label: String, primaryColour: String, expectedChannel: Int) async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(
            ASSFixture.data(text: "Colour", primaryColour: primaryColour),
            format: .ass
        )

        let frame = try #require(await renderer.frame(at: 2))
        let pixels = try rendered(try #require(frame.image))
        let opaque = pixels.opaque
        #expect(!opaque.isEmpty, "\(label): no opaque pixels to sample")

        let channels = [
            opaque.reduce(0) { $0 + Int($1.red) },
            opaque.reduce(0) { $0 + Int($1.green) },
            opaque.reduce(0) { $0 + Int($1.blue) },
        ]
        let dominant = try #require(channels.indices.max(by: { channels[$0] < channels[$1] }))
        #expect(dominant == expectedChannel, "\(label): channel totals \(channels)")
        // Premultiplied by a near-255 alpha, so the dominant channel is near-full.
        #expect(channels[dominant] / opaque.count > 200, "\(label): channel totals \(channels)")
    }

    @Test("a style override repaints dialogue, and removing it restores the authored colour")
    func styleOverride() async throws {
        let renderer = await makeProbeRenderer()
        // Authored red, no inline colour tag, so the style override is what decides.
        try await renderer.load(
            ASSFixture.data(text: "Colour", primaryColour: "&H000000FF"),
            format: .ass
        )

        func dominantChannel() async throws -> Int {
            let frame = try #require(await renderer.frame(at: 2))
            let opaque = try rendered(try #require(frame.image)).opaque
            let channels = [
                opaque.reduce(0) { $0 + Int($1.red) },
                opaque.reduce(0) { $0 + Int($1.green) },
                opaque.reduce(0) { $0 + Int($1.blue) },
            ]
            return try #require(channels.indices.max(by: { channels[$0] < channels[$1] }))
        }

        #expect(try await dominantChannel() == 0)

        await renderer.setStyleOverride(
            SubtitleStyleOverride(primaryColor: SubtitleColor(red: 0, green: 1, blue: 0))
        )
        #expect(try await dominantChannel() == 1)

        await renderer.setStyleOverride(nil)
        #expect(try await dominantChannel() == 0)
    }

    /// libass keeps the `Name` pointer from the override style rather than copying
    /// it, so repeatedly swapping overrides is the shape that exposes a lifetime
    /// mistake. Meaningful under the address sanitizer; harmless without it.
    @Test("overrides can be swapped repeatedly without corrupting the engine")
    func repeatedStyleOverrides() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(ASSFixture.data(text: "Churn"), format: .ass)

        for step in 0..<12 {
            await renderer.setStyleOverride(
                step.isMultiple(of: 3)
                    ? nil
                    : SubtitleStyleOverride(
                        fontFamily: step.isMultiple(of: 2) ? SubtitleFontBundle.serifFamily : SubtitleFontBundle.sansFamily,
                        fontScale: 1 + Double(step) / 10,
                        primaryColor: SubtitleColor(red: Double(step) / 12, green: 1, blue: 0)
                    )
            )
            #expect(try #require(await renderer.frame(at: 2)).image != nil, "step \(step)")
        }
    }

    /// The caption "opaque box" style. The box is a solid fill behind the line, so
    /// it paints the padding band above the glyphs — a place the un-boxed style
    /// leaves completely clear.
    @Test("the opaque box paints the padding around glyphs that stays clear without it")
    func opaqueBoxOverride() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(ASSFixture.data(text: "Boxed"), format: .ass)

        await renderer.setStyleOverride(nil)
        let plain = try #require(await renderer.frame(at: 2))
        await renderer.setStyleOverride(SubtitleStyleOverride(opaqueBox: true))
        let boxed = try #require(await renderer.frame(at: 2))

        // The box extends the drawn area on every side.
        #expect(boxed.imageRect.minY < plain.imageRect.minY)
        #expect(boxed.imageRect.maxY > plain.imageRect.maxY)
        #expect(boxed.imageRect.minX < plain.imageRect.minX)
        #expect(boxed.imageRect.maxX > plain.imageRect.maxX)

        // A canvas point above every glyph but inside the box's padding.
        let padding = CGPoint(x: plain.imageRect.midX, y: plain.imageRect.minY - 3)
        #expect(try alpha(of: plain, atCanvas: padding) == 0)
        #expect(try alpha(of: boxed, atCanvas: padding) > 250)

        // A solid fill, not merely a fatter outline (measured 0.61 vs 0.14).
        #expect(try opaqueFraction(of: boxed) > 0.55)
        #expect(try opaqueFraction(of: plain) < 0.25)
    }

    /// The app maps per-device sizing onto converted tracks with computed scales
    /// below 1, so shrinking has to work as plainly as growing does.
    ///
    /// The comparison is deliberately loose: `fontScale` multiplies the size fed
    /// to the rasteriser exactly, but the measured ink box also carries a roughly
    /// constant antialiasing fringe, which is a larger share of a smaller glyph.
    /// Monotonicity is the property the app actually depends on.
    @Test("fractional font scales shrink the text monotonically")
    func fractionalFontScale() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(ASSFixture.data(text: "Measure"), format: .ass)
        let authored = try #require(await renderer.frame(at: 2)).imageRect

        var widths: [Double] = []
        for scale in [0.6, 0.7, 0.8] {
            await renderer.setStyleOverride(SubtitleStyleOverride(fontScale: scale))
            let rect = try #require(await renderer.frame(at: 2)).imageRect
            let ratio = rect.width / authored.width
            #expect(ratio < 1, "scale \(scale) did not shrink: ratio \(ratio)")
            #expect(abs(ratio - scale) < 0.08, "scale \(scale) gave width ratio \(ratio)")
            widths.append(rect.width)
        }
        #expect(widths == widths.sorted(), "widths not monotonic: \(widths)")
        #expect(Set(widths).count == widths.count, "scales collapsed to one width: \(widths)")
    }

    @Test("a font scale override grows the rendered text")
    func fontScaleOverride() async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(ASSFixture.data(text: "Measure"), format: .ass)

        let authored = try #require(await renderer.frame(at: 2)).imageRect
        await renderer.setStyleOverride(SubtitleStyleOverride(fontScale: 2))
        let scaled = try #require(await renderer.frame(at: 2)).imageRect

        // Advance width tracks the scale almost exactly (measured 95pt -> 190pt).
        #expect(scaled.width > authored.width * 1.8)
        // Height is the ink box of these particular glyphs, so it grows without
        // tracking the scale linearly (measured 32pt -> 48pt).
        #expect(scaled.height > authored.height)

        await renderer.setStyleOverride(nil)
        #expect(try #require(await renderer.frame(at: 2)).imageRect.width == authored.width)
    }

    /// Converted sidecars have to survive the whole path, not just the converter.
    @Test("converted sidecars render", arguments: [
        (SubtitleSourceFormat.srt, SRTFixture.text("Sidecar")),
        (SubtitleSourceFormat.vtt, "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nSidecar"),
    ] as [(SubtitleSourceFormat, String)])
    func sidecarRoundTrip(format: SubtitleSourceFormat, source: String) async throws {
        let renderer = await makeProbeRenderer()
        try await renderer.load(Data(source.utf8), format: format)

        let frame = try #require(await renderer.frame(at: 2))
        let image = try #require(frame.image)
        #expect(try rendered(image).opaque.count > 50)
        // The synthesized Default style is bottom-centre.
        #expect(frame.imageRect.midY > CGFloat(ASSFixture.playResY) * 2 / 3)
    }

    /// libass stacks simultaneous events once they are separate Dialogue lines.
    /// Converted cues have to keep that property, which means not emitting `\pos`
    /// for cues that carry no placement settings.
    @Test("simultaneous converted cues stack instead of overlapping")
    func simultaneousCuesStack() async throws {
        let single = try await renderedRect(
            vtt: "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nFirst"
        )
        let stacked = try await renderedRect(
            vtt: """
            WEBVTT

            00:00:01.000 --> 00:00:03.000
            First

            00:00:01.000 --> 00:00:03.000
            Second
            """
        )
        // Two stacked lines occupy roughly twice the height of one.
        #expect(stacked.height > single.height * 1.6)
        #expect(stacked.maxY <= CGFloat(ASSFixture.playResY))
    }

    private func renderedRect(vtt: String) async throws -> CGRect {
        let renderer = await makeProbeRenderer()
        try await renderer.load(Data(vtt.utf8), format: .vtt)
        return try #require(await renderer.frame(at: 2)).imageRect
    }

    // MARK: - Failure modes

    @Test("input that carries no cue is rejected rather than silently blank", arguments: [
        (SubtitleSourceFormat.srt, Data("not a subtitle file".utf8), SubtitleError.noCues),
        (SubtitleSourceFormat.vtt, Data("WEBVTT\n\n".utf8), SubtitleError.noCues),
        (SubtitleSourceFormat.ass, Data(), SubtitleError.noCues),
        // Legacy single-byte sidecars are a real case; the contract is a clean throw.
        (SubtitleSourceFormat.srt, Data([0xFF, 0xFE, 0xFF]), SubtitleError.undecodableText),
    ] as [(SubtitleSourceFormat, Data, SubtitleError)])
    func rejectsUnusableInput(format: SubtitleSourceFormat, data: Data, expected: SubtitleError) async {
        let renderer = await makeProbeRenderer()
        await #expect(throws: expected) {
            try await renderer.load(data, format: format)
        }
    }

    @Test("no frame is produced before a canvas is set")
    func requiresCanvas() async throws {
        let renderer = SubtitleRenderer()
        try await renderer.load(ASSFixture.data(text: "Hello"), format: .ass)
        #expect(await renderer.frame(at: 2) == nil)

        await renderer.setCanvas(size: CGSize(width: 640, height: 360), scale: 1, storageSize: nil)
        #expect(await renderer.frame(at: 2) != nil)
    }

    /// A corrupt media header can report nonsense dimensions, and they reach
    /// libass as C ints. Narrowing them must degrade, not trap.
    @Test("nonsense dimensions degrade instead of trapping", arguments: [
        ("infinite storage width", CGSize(width: 640, height: 360),
         CGSize(width: CGFloat.infinity, height: 360), true),
        ("storage size beyond Int32", CGSize(width: 640, height: 360),
         CGSize(width: 1e12, height: 1e12), true),
        ("NaN canvas", CGSize(width: CGFloat.nan, height: CGFloat.nan), nil, false),
        ("zero canvas", CGSize(width: 0, height: 0), nil, false),
        ("negative canvas", CGSize(width: -640, height: -360), nil, false),
    ] as [(String, CGSize, CGSize?, Bool)])
    func hostileDimensions(
        label: String,
        canvas: CGSize,
        storage: CGSize?,
        rendersFrame: Bool
    ) async throws {
        let renderer = SubtitleRenderer()
        try await renderer.load(ASSFixture.data(text: "Hello"), format: .ass)
        await renderer.setCanvas(size: canvas, scale: 1, storageSize: storage)

        // A bad storage size only costs correct `\pos` scaling; a bad canvas means
        // there is nowhere to draw, so no frame at all.
        #expect(await (renderer.frame(at: 2) != nil) == rendersFrame, "\(label)")
    }

    /// The canvas is in points; frames come back in pixels.
    @Test("the retina scale multiplies through to the frame canvas")
    func canvasScale() async throws {
        let renderer = SubtitleRenderer()
        try await renderer.load(ASSFixture.data(text: "Hello"), format: .ass)
        await renderer.setCanvas(size: CGSize(width: 320, height: 180), scale: 3, storageSize: nil)

        let frame = try #require(await renderer.frame(at: 2))
        #expect(frame.canvasSize == CGSize(width: 960, height: 540))
    }
}

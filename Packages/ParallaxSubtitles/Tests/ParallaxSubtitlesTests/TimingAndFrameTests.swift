import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// When a subtitle draws, when it clears, and what the overlay gets back.
@Suite("Timing and frames")
struct TimingAndFrameTests {
    private static let probeCanvas = CGSize(width: 640, height: 360)

    @Test("a line draws while its time is on screen and clears after it ends")
    func drawsThenClears() async throws {
        let renderer = try await loaded("hello.ass", canvas: Self.probeCanvas)

        let during = try await renderer.drawing(at: 1.5)
        #expect(during.frame.canvasSize == Self.probeCanvas)
        #expect(try #require(during.pixels).opaque.count > 100)

        #expect(try await renderer.drawing(at: 1.95).isBlank)
    }

    @Test("asking for a frame at an unchanged time returns no new frame")
    func unchangedTimeHasNoNewFrame() async throws {
        let renderer = try await loaded("hello.ass", canvas: Self.probeCanvas).renderer
        await renderer.setCanvas(size: Self.probeCanvas, scale: 1, storageSize: Self.probeCanvas)

        #expect(await renderer.frame(at: 1.5) != nil)
        #expect(await renderer.frame(at: 1.5) == nil)
        #expect(await renderer.frame(at: 1.95) != nil)
    }

    @Test("nothing is drawn until the overlay gives a canvas")
    func nothingWithoutACanvas() async throws {
        let renderer = SubtitleRenderer()
        try await renderer.load(try fixture("hello.ass"), format: .ass)
        #expect(await renderer.frame(at: 1.5) == nil)

        await renderer.setCanvas(size: Self.probeCanvas, scale: 1, storageSize: nil)
        #expect(await renderer.frame(at: 1.5) != nil)
    }

    /// A corrupt media header can report any size at all.
    @Test("a nonsense video or overlay size draws nothing or still draws, and never crashes", arguments: [
        ("infinite video width", probeCanvas, CGSize(width: CGFloat.infinity, height: 360), true),
        ("video size beyond Int32", probeCanvas, CGSize(width: 1e12, height: 1e12), true),
        ("NaN overlay", CGSize(width: CGFloat.nan, height: CGFloat.nan), nil, false),
        ("zero overlay", CGSize(width: 0, height: 0), nil, false),
        ("negative overlay", CGSize(width: -640, height: -360), nil, false),
    ] as [(String, CGSize, CGSize?, Bool)])
    func nonsenseSizes(label: String, canvas: CGSize, storage: CGSize?, draws: Bool) async throws {
        let renderer = SubtitleRenderer()
        try await renderer.load(try fixture("hello.ass"), format: .ass)
        await renderer.setCanvas(size: canvas, scale: 1, storageSize: storage)

        #expect(await (renderer.frame(at: 1.5) != nil) == draws, "\(label)")
    }

    @Test("the frame comes back in pixels at the screen's scale")
    func frameIsInPixels() async throws {
        let renderer = SubtitleRenderer()
        try await renderer.load(try fixture("hello.ass"), format: .ass)
        await renderer.setCanvas(size: CGSize(width: 320, height: 180), scale: 3, storageSize: nil)

        let frame = try #require(await renderer.frame(at: 1.5))
        #expect(frame.canvasSize == CGSize(width: 960, height: 540))
    }

    @Test("a file with no line in it, or an SRT that is not text, fails to load instead of drawing nothing", arguments: [
        ("no-cues/empty.srt", SubtitleError.noCues),
        ("no-cues/prose.srt", .noCues),
        ("no-cues/indices-only.srt", .noCues),
        ("no-cues/timing-no-text.srt", .noCues),
        ("no-cues/bad-timestamps.srt", .noCues),
        ("no-cues/empty.vtt", .noCues),
        ("no-cues/signature-only.vtt", .noCues),
        ("no-cues/prose.vtt", .noCues),
        ("no-cues/timing-no-text.vtt", .noCues),
        ("no-cues/empty.ass", .noCues),
        ("no-cues/not-utf8.srt", .undecodableText),
    ])
    func unusableFilesFailToLoad(path: String, error: SubtitleError) async throws {
        let renderer = SubtitleRenderer()
        let data = try fixture(path)
        let format = try format(of: path)
        await #expect(throws: error) {
            try await renderer.load(data, format: format)
        }
    }
}

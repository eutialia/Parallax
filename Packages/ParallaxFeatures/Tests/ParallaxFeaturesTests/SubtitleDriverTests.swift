import CoreGraphics
import Testing
import ParallaxCoreTestSupport
import ParallaxSubtitles
import ParallaxTestScaling
@testable import ParallaxFeatures

@MainActor
@Suite("Subtitle overlay driver", .scaledTimeLimit())
struct SubtitleDriverTests {
    private actor FakeSource: SubtitleFrameSource {
        private(set) var canvases: [CGSize] = []
        private var changed: SubtitleFrame?

        func setCanvas(size: CGSize, scale: CGFloat, storageSize: CGSize?) { canvases.append(size) }

        /// Like the renderer, a frame is handed out once, when it changes; nil means unchanged.
        func frame(at seconds: Double) -> SubtitleFrame? {
            defer { changed = nil }
            return changed
        }

        func change(to frame: SubtitleFrame) { changed = frame }
    }

    /// The player and overlay inputs the driver reads each tick, moved by the test.
    private final class Inputs {
        var source: FakeSource? = FakeSource()
        var generation = 0
        var seconds: Double? = 0
        var rect = CGRect(x: 0, y: 0, width: 390, height: 220)
        var pushes = 0
    }

    private let clock = TestClock()
    private let tick = SubtitleDriver.tick

    private func cue(_ y: CGFloat) -> SubtitleFrame {
        SubtitleFrame(image: nil, imageRect: CGRect(x: 0, y: y, width: 10, height: 10),
                      canvasSize: CGSize(width: 390, height: 220))
    }

    private func start(_ driver: SubtitleDriver, _ inputs: Inputs) async throws -> Task<Void, Never> {
        let feed = SubtitleFeed(
            source: { inputs.source.map { ($0, inputs.generation) } },
            engineSeconds: { inputs.seconds },
            clock: clock
        )
        let task = Task {
            await driver.run(feed, scale: 3) {
                SubtitleDriver.Canvas(rect: inputs.rect, storage: nil)
            } onCanvasPushed: {
                inputs.pushes += 1
            }
        }
        try await clock.waitForSleep(dueIn: tick)
        return task
    }

    private func nextTick() async throws {
        clock.advance(by: tick)
        try await clock.waitForSleep(dueIn: tick)
    }

    @Test("the canvas is pushed once per track and rect, not every tick")
    func canvasPushesOnChange() async throws {
        let driver = SubtitleDriver()
        let inputs = Inputs()
        let source = try #require(inputs.source)
        let run = try await start(driver, inputs)
        try await nextTick()
        #expect(await source.canvases.count == 1)

        inputs.generation += 1
        try await nextTick()
        inputs.rect.size.height = 300
        try await nextTick()
        #expect(await source.canvases == [CGSize(width: 390, height: 220), CGSize(width: 390, height: 220),
                                          CGSize(width: 390, height: 300)])
        #expect(inputs.pushes == 3)
        run.cancel()
        await run.value
    }

    @Test("an unreadable engine clock hides the cue, and the cue returns with the clock")
    func unreadableClockHidesTheCue() async throws {
        let driver = SubtitleDriver()
        let inputs = Inputs()
        let source = try #require(inputs.source)
        await source.change(to: cue(40))
        let run = try await start(driver, inputs)
        #expect(driver.shownFrame?.imageRect.minY == 40)

        inputs.seconds = nil
        try await nextTick()
        #expect(driver.shownFrame == nil)

        inputs.seconds = 12
        try await nextTick()
        #expect(driver.shownFrame?.imageRect.minY == 40)
        run.cancel()
        await run.value
    }

    @Test("unloading the track clears the cue, and the next track gets its canvas")
    func unloadClears() async throws {
        let driver = SubtitleDriver()
        let inputs = Inputs()
        let first = try #require(inputs.source)
        await first.change(to: cue(40))
        let run = try await start(driver, inputs)

        inputs.source = nil
        try await nextTick()
        #expect(driver.shownFrame == nil)

        let second = FakeSource()
        inputs.source = second
        try await nextTick()
        #expect(await second.canvases.count == 1)
        run.cancel()
        await run.value
    }
}

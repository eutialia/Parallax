import CoreGraphics
import Foundation
import ParallaxCoreTestSupport
import ParallaxSubtitles
import Testing

/// The driver as the overlay runs it: a real display showing a real file, the player's clock
/// moved by the test.
@MainActor
@Suite("SubtitleDriver", .timeLimit(.minutes(1)))
struct SubtitleDriverTests {
    /// What the overlay and the player feed the driver each tick.
    private final class Inputs {
        var seconds: Double? = 2
        var rect = CGRect(x: 0, y: 0, width: 390, height: 220)
        var pushes = 0
    }

    private let clock = TestClock()
    private let tick = SubtitleDriver.tick
    private let inputs = Inputs()
    private let driver = SubtitleDriver()
    private let display: SubtitleDisplay
    private let events: DisplayEvents

    private static let lines = SubtitleDocument(url: URL(string: "smb://share/film.srt")!, languageCode: nil)
    private static let authored = SubtitleDocument(url: URL(string: "smb://share/film.ass")!, languageCode: nil)

    init() throws {
        let srt = try SubtitleFixtureFile.twoLinesSRT.data
        let ass = try SubtitleFixtureFile.yellowTopLeftASS.data
        display = SubtitleDisplay { url in .data(url.pathExtension == "srt" ? srt : ass) }
        events = DisplayEvents(of: display)
    }

    private func show(_ document: SubtitleDocument) async {
        let landed = events.all.count
        display.show(document)
        await events.reach(landed + 1)
    }

    private func run() async throws -> Task<Void, Never> {
        let feed = SubtitleFeed(
            source: { [display] in display.renderer.map { ($0, display.rendererGeneration) } },
            engineSeconds: { [inputs] in inputs.seconds },
            clock: clock
        )
        let task = Task { [driver, inputs] in
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

    @Test("a new subtitle, or a new overlay size, gets its canvas before its first frame, and an unchanged one is not pushed again")
    func canvasFollowsTheSubtitleAndTheOverlay() async throws {
        await show(Self.lines)
        let running = try await run()
        #expect(inputs.pushes == 1)
        // The canvas is in pixels: the overlay is 390 x 220 points at 3x.
        #expect(driver.shownFrame?.canvasSize == CGSize(width: 1170, height: 660))

        try await nextTick()
        #expect(inputs.pushes == 1)

        inputs.rect.size.height = 300
        try await nextTick()
        #expect(inputs.pushes == 2)
        #expect(driver.shownFrame?.canvasSize == CGSize(width: 1170, height: 900))

        await show(Self.authored)
        try await nextTick()
        #expect(inputs.pushes == 3)
        // The authored file's line is in the top-left corner, the plain one's at the bottom.
        #expect((driver.shownFrame?.imageRect.maxY ?? 900) < 450)
        running.cancel()
        await running.value
    }

    @Test("while the engine clock can't be read the line is hidden, and it returns with the clock")
    func unreadableClockHidesTheLine() async throws {
        await show(Self.lines)
        let running = try await run()
        #expect(driver.shownFrame?.image != nil)

        inputs.seconds = nil
        try await nextTick()
        #expect(driver.shownFrame == nil)

        inputs.seconds = 2
        try await nextTick()
        #expect(driver.shownFrame?.image != nil)
        running.cancel()
        await running.value
    }

    @Test("turning the subtitle off clears the drawn line, and the next subtitle draws on a canvas of its own")
    func offClearsTheLine() async throws {
        await show(Self.lines)
        let running = try await run()
        #expect(driver.shownFrame?.image != nil)

        display.clear()
        try await nextTick()
        #expect(driver.shownFrame == nil)

        await show(Self.authored)
        try await nextTick()
        #expect(inputs.pushes == 2)
        #expect(driver.shownFrame?.image != nil)
        running.cancel()
        await running.value
    }
}

import Foundation
import Observation
import ParallaxSubtitles
import Testing

/// A `SubtitleDisplay` drawing a subtitle stored in the played file, whose lines arrive as the
/// file is read. The lines are those of the fixtures the display's other suite fetches whole.
@MainActor
@Suite("SubtitleDisplay — a subtitle that arrives line by line", .timeLimit(.minutes(1)))
struct SubtitleLineDisplayTests {

    @Test("an ASS subtitle's lines draw what the same script draws from a file: the author's color, in the author's corner")
    func assLinesDrawLikeTheFile() async throws {
        let file = try SubtitleFixtureFile.yellowTopLeftASS.data
        let whole = SubtitleDisplay { _ in .data(file) }
        let events = DisplayEvents(of: whole)
        whole.show(SubtitleDocument(url: URL(string: "https://media.example/Stream.ass")!, languageCode: nil))
        await events.reach(1)
        let lines = try StoredLines(assFile: file)
        let display = SubtitleDisplay { _ in .rejected }

        display.show(lines.stream, languageCode: nil)
        lines.arrive(lines.all)

        for seconds in [2.0, 6.0] {
            try await Self.until(display) { await Self.draws($0, at: seconds) }
            let streamed = try await inkDrawn(by: try #require(display.renderer), at: seconds)
            let fetched = try await inkDrawn(by: try #require(whole.renderer), at: seconds)
            #expect(streamed.frame.imageRect == fetched.frame.imageRect)
            #expect(streamed.pixels == fetched.pixels)
            #expect(streamed.pixels.contains { $0.red > 200 && $0.green > 200 && $0.blue < 60 })
        }
    }

    @Test("nothing is drawn before the first line arrives, and a line that arrives later joins the ones already drawn without the overlay being rebuilt")
    func laterLinesJoin() async throws {
        let lines = try StoredLines(assFile: try SubtitleFixtureFile.yellowTopLeftASS.data)
        let display = SubtitleDisplay { _ in .rejected }

        display.show(lines.stream, languageCode: nil)
        await Task.yield()
        #expect(display.renderer == nil)
        #expect(display.loading == nil)

        lines.arrive([lines.all[1]])
        try await Self.until(display) { await Self.draws($0, at: 6) }
        let renderer = try #require(display.renderer)
        let generation = display.rendererGeneration
        #expect(!(await Self.draws(renderer, at: 2)))

        lines.arrive([lines.all[0]])
        try await Self.until(display) { await Self.draws($0, at: 2) }
        #expect(await Self.draws(renderer, at: 6))
        #expect(display.renderer === renderer)
        #expect(display.rendererGeneration == generation)
    }

    @Test("my style reaches an SRT subtitle's lines, and each line shows for its own time")
    func srtLinesTakeMyStyle() async throws {
        let lines = StoredLines(srt: [(1, 2, "Hello there"), (5, 2, "Second line")])
        let display = SubtitleDisplay { _ in .rejected }
        display.applyAppearance(converted: SubtitleStyleOverride(primaryColor: SubtitleColor(red: 1, green: 0, blue: 0)))

        display.show(lines.stream, languageCode: "eng")
        lines.arrive(lines.all)

        try await Self.until(display) { await Self.draws($0, at: 6) }
        let renderer = try #require(display.renderer)
        let drawn = try await inkDrawn(by: renderer, at: 2)
        #expect(drawn.pixels.contains { $0.red > 200 && $0.green < 60 && $0.blue < 60 })
        #expect(!drawn.pixels.contains { $0.red > 200 && $0.green > 200 && $0.blue > 200 })
        for (seconds, shows) in [(0.5, false), (1.5, true), (3.5, false), (5.5, true), (7.5, false)] {
            #expect(await Self.draws(renderer, at: seconds) == shows, "at \(seconds) s")
        }
    }

    @Test("a change of my font redraws every line that has arrived in the new font, with the old drawing up until then, and lines keep arriving")
    func fontChangeKeepsTheLines() async throws {
        let lines = StoredLines(srt: [(1, 2, "Hello there"), (5, 2, "Second line")])
        let display = SubtitleDisplay { _ in .rejected }
        display.show(lines.stream, languageCode: "eng")
        lines.arrive([lines.all[0]])
        try await Self.until(display) { await Self.draws($0, at: 2) }
        let before = try #require(display.renderer)
        let sans = try await inkDrawn(by: before, at: 2)

        display.applyAppearance(converted: SubtitleStyleOverride(fontFamily: "Noto Serif"))
        #expect(display.renderer === before)
        try await Self.until(display) { $0 !== before }
        let serif = try await inkDrawn(by: try #require(display.renderer), at: 2)
        #expect(serif.pixels != sans.pixels || serif.frame.imageRect != sans.frame.imageRect)

        lines.arrive([lines.all[1]])
        try await Self.until(display) { await Self.draws($0, at: 6) }
        #expect(await Self.draws(try #require(display.renderer), at: 2))
    }

    @Test("lines that arrive after the subtitle is cleared, or after another is shown, draw nothing")
    func staleLinesDrawNothing() async throws {
        let file = try SubtitleFixtureFile.twoLinesSRT.data
        let lines = try StoredLines(assFile: try SubtitleFixtureFile.yellowTopLeftASS.data)
        let display = SubtitleDisplay { _ in .data(file) }
        let events = DisplayEvents(of: display)

        display.show(lines.stream, languageCode: nil)
        lines.arrive([lines.all[0]])
        try await Self.until(display) { await Self.draws($0, at: 2) }
        display.clear()
        lines.arrive([lines.all[1]])
        for _ in 0..<50 { await Task.yield() }
        #expect(display.renderer == nil)

        // Cleared while the lines that just arrived are being loaded.
        display.show(lines.stream, languageCode: nil)
        for _ in 0..<4 { await Task.yield() }
        display.clear()
        for _ in 0..<200 { await Task.yield() }
        #expect(display.renderer == nil)

        display.show(lines.stream, languageCode: nil)
        display.show(SubtitleDocument(url: URL(string: "https://media.example/Stream.srt")!, languageCode: nil))
        await events.reach(1)
        lines.arrive(lines.all)
        for _ in 0..<50 { await Task.yield() }
        #expect(display.shownInfo == SidecarSubtitleInfo(format: .srt, byteCount: file.count))

        // A subtitle whose lines have yet to arrive takes the other one off the screen.
        display.show(StoredLines(srt: []).stream, languageCode: nil)
        #expect(display.renderer == nil)
    }

    /// Lines as a Matroska file stores them, handed to whoever is listening when they arrive.
    @MainActor
    final class StoredLines {
        let format: SubtitleLineFormat
        let all: [SubtitleLine]
        private var listeners: [AsyncStream<[SubtitleLine]>.Continuation] = []
        private var arrived: [SubtitleLine] = []

        /// The script up to its events as the header, and each `Dialogue:` line as Matroska
        /// stores it: its place in the file, then its fields without the two times.
        init(assFile: Data) throws {
            let text = String(decoding: assFile, as: UTF8.self)
            let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            format = .ass(header: Data(rows.filter { !$0.hasPrefix("Dialogue:") }.joined(separator: "\n").utf8))
            all = try rows.filter { $0.hasPrefix("Dialogue:") }.enumerated().map { place, row in
                let fields = row.dropFirst("Dialogue: ".count).split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
                let start = try #require(Self.seconds(fields[1])), end = try #require(Self.seconds(fields[2]))
                return SubtitleLine(
                    start: .seconds(start), duration: .seconds(end - start),
                    content: Data("\(place),\(fields[0]),\(fields[3])".utf8))
            }
        }

        init(srt lines: [(start: Int, length: Int, text: String)]) {
            format = .srt
            all = lines.map { SubtitleLine(start: .seconds($0.start), duration: .seconds($0.length), content: Data($0.text.utf8)) }
        }

        /// `H:MM:SS.cc`.
        private static func seconds(_ timecode: Substring) -> Double? {
            let parts = timecode.split(separator: ":").compactMap { Double($0) }
            return parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : nil
        }

        nonisolated var stream: SubtitleLineStream {
            SubtitleLineStream(format: format) { [weak self] in
                AsyncStream { continuation in
                    Task { @MainActor in
                        guard let self else { return continuation.finish() }
                        continuation.yield(self.arrived)
                        self.listeners.append(continuation)
                    }
                }
            }
        }

        func arrive(_ lines: [SubtitleLine]) {
            arrived += lines
            listeners.forEach { $0.yield(lines) }
        }
    }

    private static func draws(_ renderer: SubtitleRenderer, at seconds: Double) async -> Bool {
        let size = CGSize(width: 640, height: 360)
        await renderer.setCanvas(size: size, scale: 1, storageSize: size)
        return await renderer.frame(at: seconds)?.image != nil
    }

    /// Returns once the display has a renderer `condition` holds for, looking again each time
    /// the display loads lines.
    private static func until(
        _ display: SubtitleDisplay, _ condition: @escaping (SubtitleRenderer) async -> Bool
    ) async throws {
        for await renderer in Observations({ (display.renderer, display.shownInfo).0 }) {
            if let renderer, await condition(renderer) { return }
        }
        try #require(Bool(false), "the display went away")
    }
}

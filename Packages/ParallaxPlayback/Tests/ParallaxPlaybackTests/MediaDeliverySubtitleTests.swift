import Foundation
import Testing
import ParallaxPlayback

/// The text subtitles of a file `MediaDelivery` bridges. The fixture holds an ASS and an SRT
/// stream of ten lines each: line k starts at 1 + 4k seconds and lasts two.
@Suite("MediaDelivery — subtitles stored in the file", .timeLimit(.minutes(1)))
struct MediaDeliverySubtitleTests {

    @Test("a Matroska file's ASS and SRT streams are listed in file order, each with its title, its forced and hard-of-hearing flags, and the ASS script's styles")
    func textStreamsAreListed() async throws {
        let file = try await DeliveredFile.start("text-subtitles")
        let subtitles = file.delivery.subtitles
        await file.stop()

        #expect(subtitles.map(\.id) == [2, 3])
        #expect(subtitles.map(\.title) == ["ASS", "SRT"])
        #expect(subtitles.map(\.language) == [nil, nil])
        #expect(subtitles.map(\.isHearingImpaired) == [true, false])
        #expect(subtitles.map(\.isForced) == [false, true])
        guard case .ass(let header) = subtitles.first?.format else {
            Issue.record("\(subtitles)")
            return
        }
        let script = String(decoding: header, as: UTF8.self)
        #expect(script.contains("PlayResX: 1920"))
        #expect(script.contains("Style: Corner,Arial,96,&H0000FFFF"))
        #expect(subtitles.last?.format == .srt)
    }

    @Test("a file fetched whole, twice over, video and audio, hands over each line once at its own time")
    func eachLineArrivesOnce() async throws {
        let file = try await DeliveredFile.start("text-subtitles")
        // Listening starts here, before anything is fetched.
        let (assLines, srtLines) = (file.delivery.lines(of: 2), file.delivery.lines(of: 3))
        async let ass = Self.collected(assLines)
        async let srt = Self.collected(srtLines)
        for name in ["v", "a0", "v", "a0"] { _ = try await file.rendition(name) }
        await file.stop()

        let expected = (0..<10).map { Line(start: .seconds(1 + 4 * $0), duration: .seconds(2), text: "line \($0)") }
        #expect(await ass.sorted() == expected.map {
            Line(start: $0.start, duration: $0.duration, text: "ASS \($0.text)")
        })
        #expect(await srt.sorted() == expected.map {
            Line(start: $0.start, duration: $0.duration, text: "SRT \($0.text)")
        })
    }

    @Test("an ASS line arrives as Matroska stores it: its read order, layer, style, name, margins, effect and text")
    func assLineKeepsItsFields() async throws {
        let file = try await DeliveredFile.start("text-subtitles")
        _ = try await file.bytes("v-4.m4s")
        let lines = await Self.first(of: file.delivery.lines(of: 2))
        await file.stop()

        #expect(lines.map { String(decoding: $0.content, as: UTF8.self) } == ["2,0,Corner,,0,0,0,,ASS line 2"])
    }

    @Test("a line is handed over when the segment its start falls in is fetched, and someone who starts listening later is told every line read so far, in time order")
    func linesArriveWithTheirSegment() async throws {
        let file = try await DeliveredFile.start("text-subtitles")
        let before = await Self.first(of: file.delivery.lines(of: 3))
        // Segments are two seconds long: line k starts in segment 2k.
        for segment in ["v-18", "v-8", "a0-2", "v-12", "a0-0"] { _ = try await file.bytes("\(segment).m4s") }
        let after = await Self.first(of: file.delivery.lines(of: 3))
        await file.stop()

        #expect(before.isEmpty)
        #expect(after.map(\.start) == [1, 5, 17, 25, 37].map { .seconds($0) })
    }

    @Test("segments fetched at the same time hand their lines to everyone listening")
    func overlappingFetchesReachEveryListener() async throws {
        let file = try await DeliveredFile.start("text-subtitles")
        let (first, second) = (file.delivery.lines(of: 3), file.delivery.lines(of: 3))
        async let one = Self.collected(first)
        async let other = Self.collected(second)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for segment in 0..<20 {
                group.addTask { _ = try await file.bytes("v-\(segment).m4s") }
                group.addTask { _ = try await file.bytes("a0-\(segment).m4s") }
            }
            try await group.waitForAll()
        }
        await file.stop()

        let starts = (0..<10).map { Duration.seconds(1 + 4 * $0) }
        #expect(await one.map(\.start).sorted() == starts)
        #expect(await other.map(\.start).sorted() == starts)
    }

    @Test("a file whose streams start at ten minutes hands over its lines in the time AVPlayer plays it at, from zero")
    func lateStartingFileIsTimedFromZero() async throws {
        let file = try await DeliveredFile.start("text-subtitles-late")
        _ = try await file.rendition("v")
        let lines = await Self.first(of: file.delivery.lines(of: 3))
        await file.stop()

        #expect(lines.map(\.start) == (0..<10).map { .seconds(1 + 4 * $0) })
    }

    @Test("listening ends when the delivery stops")
    func listeningEndsAtStop() async throws {
        let file = try await DeliveredFile.start("text-subtitles")
        let listening = file.delivery.lines(of: 3)
        async let early = Self.collected(listening)
        await file.stop()

        #expect(await early.isEmpty)
        #expect(await Self.collected(file.delivery.lines(of: 3)).isEmpty)
    }

    struct Line: Equatable, Comparable, CustomStringConvertible {
        let start: Duration
        let duration: Duration
        let text: String

        var description: String { "\(text) at \(start) for \(duration)" }
        static func < (one: Line, other: Line) -> Bool { one.start < other.start }
    }

    /// Every line handed over until listening ends, with an ASS line's text alone.
    private static func collected(_ lines: AsyncStream<[EmbeddedSubtitleLine]>) async -> [Line] {
        var all: [Line] = []
        for await batch in lines {
            all += batch.map {
                let content = String(decoding: $0.content, as: UTF8.self)
                return Line(
                    start: $0.start, duration: $0.duration,
                    text: content.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).last.map(String.init) ?? content)
            }
        }
        return all
    }

    /// What someone who starts listening now is told at once.
    private static func first(of lines: AsyncStream<[EmbeddedSubtitleLine]>) async -> [EmbeddedSubtitleLine] {
        var iterator = lines.makeAsyncIterator()
        return await iterator.next() ?? []
    }
}

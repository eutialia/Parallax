import Foundation
import Synchronization
import Testing
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// Where a bridged file is cut into segments, over keyframe lists shaped like real indexes:
/// mostly short intervals, some long ones, and now and then an index that stops early.
@Suite("Segment cuts")
struct SegmentCutsProperties {

    private struct Index {
        let keyframes: [IndexedKeyframe]
        let fileSize: Int64
        let fileEnd: Int64
    }

    private static func index(_ random: inout SeededGenerator) -> Index {
        let second: Int64 = 1_000_000_000
        var time = Int64.random(in: -2 * second...5 * second, using: &random)
        var position = Int64.random(in: 0...(1 << 20), using: &random)
        let keyframes = (0..<Int.random(in: 2...120, using: &random)).map { _ in
            defer {
                let kind = Int.random(in: 0..<20, using: &random)
                time += kind < 10 ? .random(in: 40_000_000...second, using: &random)
                    : kind < 16 ? .random(in: second...4 * second, using: &random)
                    : kind < 19 ? .random(in: 4 * second...40 * second, using: &random)
                    : .random(in: second...900 * second, using: &random)
                position += .random(in: 1...(5 << 20), using: &random)
            }
            return IndexedKeyframe(time: time, position: position)
        }
        let last = keyframes[keyframes.count - 1]
        let tail = Int.random(in: 0..<10, using: &random) == 0
            ? Int64.random(in: 500 * second...800 * second, using: &random)
            : Int64.random(in: 0...10 * second, using: &random)
        return Index(
            keyframes: keyframes, fileSize: last.position + .random(in: 1...(5 << 20), using: &random),
            fileEnd: last.time + tail)
    }

    private static let cases = 500

    @Test("the segments tile the keyframes, each at least two seconds but the last, and none longer than it must be")
    func segmentsTileTheIndex() throws {
        var random = SeededGenerator(seed: 0x6375_7473)
        for run in 0..<Self.cases {
            let index = Self.index(&random)
            let keyframes = index.keyframes
            guard let cuts = try? SegmentCuts(at: keyframes, fileSize: index.fileSize, end: { _ in index.fileEnd }) else { continue }
            let spans = cuts.spans

            #expect(spans.first?.lowerBound == 0, "run \(run)")
            #expect(spans.last?.upperBound == keyframes.count, "run \(run)")
            #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound && !$0.isEmpty }, "run \(run)")
            for (span, next) in zip(spans, spans.dropFirst()) {
                let start = keyframes[span.lowerBound].time
                #expect(keyframes[next.lowerBound].time - start >= BridgePlan.targetSegmentLength, "run \(run)")
                #expect(keyframes[span].dropFirst().allSatisfy { $0.time - start < BridgePlan.targetSegmentLength }, "run \(run)")
            }
        }
    }

    @Test("cutting the segments' first keyframes again gives each its own segment")
    func cuttingAgainChangesNothing() throws {
        var random = SeededGenerator(seed: 0x6167_6169_6E)
        for run in 0..<Self.cases {
            let index = Self.index(&random)
            guard let cuts = try? SegmentCuts(at: index.keyframes, fileSize: index.fileSize, end: { _ in index.fileEnd }),
                  cuts.spans.count >= 2
            else { continue }
            let starts = cuts.spans.map { index.keyframes[$0.lowerBound] }

            let again = try SegmentCuts(at: starts, fileSize: index.fileSize, end: { _ in index.fileEnd })

            #expect(again.spans == starts.indices.map { $0..<$0 + 1 }, "run \(run)")
            #expect(again.boundaries == cuts.boundaries, "run \(run)")
            #expect(again.bytes == cuts.bytes, "run \(run)")
        }
    }

    @Test("the segments' bytes add up to the file from its first keyframe, and their times run from it to the file's end")
    func bytesAndTimesTelescope() throws {
        var random = SeededGenerator(seed: 0x7465_6C65)
        let clock = MediaClock(timescale: BridgePlan.videoTimescale, origin: 0, grid: nil)
        for run in 0..<Self.cases {
            let index = Self.index(&random)
            let keyframes = index.keyframes
            let asked = Mutex<[Int64]>([])
            guard let cuts = try? SegmentCuts(at: keyframes, fileSize: index.fileSize, end: { start in
                asked.withLock { $0.append(start) }
                return index.fileEnd
            }) else { continue }
            let segments = cuts.segments(on: clock)

            #expect(asked.withLock { $0 } == [keyframes[cuts.spans[cuts.spans.count - 1].lowerBound].time], "run \(run)")
            #expect(cuts.bytes.allSatisfy { $0 > 0 }, "run \(run)")
            #expect(cuts.bytes.reduce(0, +) == index.fileSize - keyframes[0].position, "run \(run)")
            #expect(cuts.boundaries == cuts.spans.map { keyframes[$0.lowerBound].time } + [index.fileEnd], "run \(run)")
            #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.end == $1.start }, "run \(run)")
            let total = clock.seconds(at: index.fileEnd) - clock.seconds(at: keyframes[0].time)
            #expect(abs(segments.map(\.seconds).reduce(0, +) - total) < 1e-6, "run \(run)")
            let from = Int.random(in: cuts.spans.indices, using: &random)
            let stretched = cuts.segment(from: from, on: clock)
            #expect(stretched.entries == cuts.spans[from] && stretched.start == segments[from].start, "run \(run)")
            #expect(stretched.end == index.fileEnd, "run \(run)")
            #expect(abs(stretched.seconds - segments[from...].map(\.seconds).reduce(0, +)) < 1e-6, "run \(run)")
        }
    }

    @Test("a file that runs more than ten minutes past its last keyframe is refused, naming where the index stops")
    func indexThatStopsIsRefused() {
        var random = SeededGenerator(seed: 0x6761_70)
        for run in 0..<Self.cases {
            let index = Self.index(&random)
            let first = index.keyframes[0].time, last = index.keyframes[index.keyframes.count - 1].time
            let stops = Duration.nanoseconds(index.fileEnd - last) > .seconds(600)

            let result = Result { try SegmentCuts(at: index.keyframes, fileSize: index.fileSize, end: { _ in index.fileEnd }) }

            switch result {
            case .success: #expect(!stops, "run \(run)")
            case .failure(let error):
                #expect(stops, "run \(run)")
                #expect(error as? BridgeRefusal == .indexGap(after: Int((last - first) / 1_000_000_000)), "run \(run)")
            }
        }
    }

    @Test("a refusal names a time as hours, minutes and seconds that read back as the same time")
    func refusalTimeReadsBack() throws {
        var random = SeededGenerator(seed: 0x636C_6F63)
        for _ in 0..<Self.cases {
            let seconds = Int.random(in: 0...400_000, using: &random)
            let line = "\(BridgeRefusal.indexGap(after: seconds))"
            let parts = try #require(line.split(separator: " ").last).split(separator: ":")

            #expect(line.hasPrefix("no keyframe index after "))
            #expect(parts.count == 3 && parts.dropFirst().allSatisfy { $0.count == 2 }, "\(line)")
            #expect(parts.compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 } == seconds, "\(line)")
        }
    }

    @Test("the last index a track holds audio at is the one a scan from the start finds, and a track that lasts costs one question")
    func lastIndexMatchesAScan() async throws {
        var random = SeededGenerator(seed: 0x6C61_7374)
        for _ in 0..<Self.cases {
            let count = Int.random(in: 1...300, using: &random)
            let lastWith = Int.random(in: 0..<count, using: &random)
            let asked = Mutex<[Int]>([])

            let found = try await BridgePlan.lastIndex(below: count) { index in
                asked.withLock { $0.append(index) }
                return index <= lastWith
            }
            let questions = asked.withLock { $0 }

            #expect(found == lastWith, "\(lastWith) of \(count)")
            #expect(questions.allSatisfy { (0..<count).contains($0) }, "\(questions)")
            #expect(questions.count <= 2 * (Int.bitWidth - count.leadingZeroBitCount) + 1, "\(questions.count) for \(count)")
            if lastWith == count - 1, count > 1 { #expect(questions.count == 1, "\(questions)") }
        }
    }
}

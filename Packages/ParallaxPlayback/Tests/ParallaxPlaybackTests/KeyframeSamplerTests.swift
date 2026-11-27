import Testing
import ParallaxCoreTestSupport
import ParallaxTestScaling
@testable import ParallaxPlayback

/// The sampler's rules, held over generated files. A case's inputs come from its seed, which a
/// failure prints.
@Suite("KeyframeSampler — properties", .scaledTimeLimit())
struct KeyframeSamplerTests {

    /// A file known only by where its video keyframes are. A keyframe's time is its position.
    private struct Layout: CustomStringConvertible {
        let fileSize: Int64
        /// In file order, each once, inside the file.
        let keyframes: [Int64]
        let limits: KeyframeSampler.Limits

        var description: String {
            "\(fileSize) bytes, spacing \(limits.densestSpacing), largest \(limits.largestSegment), "
                + "\(keyframes.count) keyframes from \(keyframes.first.map(String.init) ?? "none")"
        }

        /// The widest stretch with no keyframe in it: from one keyframe to the next, or from the
        /// last to the file's end.
        var widestInterval: Int64 {
            zip(keyframes, keyframes.dropFirst() + [fileSize]).map { $1 - $0 }.max() ?? fileSize
        }

        /// What a read of `range` comes to: the first keyframe that starts in it.
        func keyframe(in range: Range<Int64>) -> IndexedKeyframe? {
            var (low, high) = (0, keyframes.count)
            while low < high {
                let middle = (low + high) / 2
                if keyframes[middle] < range.lowerBound { low = middle + 1 } else { high = middle }
            }
            guard low < keyframes.count, range.contains(keyframes[low]) else { return nil }
            return IndexedKeyframe(time: keyframes[low], position: keyframes[low])
        }

        static func random(using random: inout SeededGenerator) -> Layout {
            let fileSize = Bool.random(using: &random)
                ? Int64.random(in: 1...200, using: &random) : Int64.random(in: 1_000...2_000_000, using: &random)
            // Few enough samples that a case stays quick: a stretch narrower than a 400th of
            // the file is left alone.
            let spacing = fileSize < 1_000
                ? Int64.random(in: 0...fileSize, using: &random)
                : Int64.random(in: fileSize / 400...fileSize / 8, using: &random)
            let largest = Int64.random(in: max(spacing, 1)...fileSize, using: &random)
            let widest = [fileSize / 200, fileSize / 20, fileSize / 3].randomElement(using: &random)!
            var keyframes: [Int64] = []
            var at = Int64.random(in: 0...max(widest, 1), using: &random)
            while at < fileSize {
                keyframes.append(at)
                // Mostly even, now and then a long stretch with none.
                at += Int.random(in: 0..<10, using: &random) == 0
                    ? Int64.random(in: 1...max(fileSize / 2, 1), using: &random)
                    : Int64.random(in: 1...max(widest, 1), using: &random)
            }
            return Layout(
                fileSize: fileSize, keyframes: keyframes,
                limits: .init(densestSpacing: spacing, largestSegment: largest))
        }
    }

    /// Samples a file as the demuxer does, the reader's answers given by `answer`. The time is up
    /// from the `hurriedFrom`th sample on. Stops after one sample more than the file has bytes,
    /// should the sampling not end.
    private static func sampled(
        _ fileSize: Int64, _ limits: KeyframeSampler.Limits, hurriedFrom: Int = .max,
        answer: (Range<Int64>) -> IndexedKeyframe?
    ) -> [KeyframeSampler.Sample] {
        let sampler = KeyframeSampler(fileSize: fileSize, limits: limits)
        var samples: [KeyframeSampler.Sample] = []
        while samples.count <= fileSize,
              let range = sampler.nextRange(after: samples, timeIsUp: samples.count >= hurriedFrom) {
            samples.append(.init(searched: range, keyframe: answer(range)))
        }
        return samples
    }

    /// Where the read of a sample stopped: past its keyframe, or at its range's end. It reads
    /// one byte at least.
    private static func readThrough(_ sample: KeyframeSampler.Sample) -> Int64 {
        max(sample.searched.lowerBound + 1, sample.keyframe.map { $0.position + 1 } ?? sample.searched.upperBound)
    }

    /// From each listed keyframe to the next, and from the last to the file's end.
    private static func gaps(between positions: [Int64], fileSize: Int64) -> [Int64] {
        zip(positions, positions.dropFirst() + [fileSize]).map { $1 - $0 }
    }

    private static let cases = 300

    @Test("a file with no video keyframe is sampled once, all of it")
    func fileWithNoKeyframeIsSampledOnce() {
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let layout = Layout.random(using: &random)
            let samples = Self.sampled(
                layout.fileSize, layout.limits, hurriedFrom: Int.random(in: 0...3, using: &random)) { _ in nil }

            #expect(samples.map(\.searched) == [0..<layout.fileSize], "seed \(seed): \(layout)")
        }
    }

    /// A reader may come to a keyframe stored before where its sample starts, as a byte seek
    /// into a program stream can.
    @Test("whatever the reader answers, sampling ends, inside the file, and no byte is read through twice")
    func samplingEndsAndReadsEachByteOnce() {
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let fileSize = Int64.random(in: 1...5_000, using: &random)
            let limits = KeyframeSampler.Limits(
                densestSpacing: Int64.random(in: 0...fileSize / 4, using: &random),
                largestSegment: Int64.random(in: 1...fileSize, using: &random))
            let samples = Self.sampled(fileSize, limits, hurriedFrom: Int.random(in: 0...20, using: &random)) { range in
                guard Bool.random(using: &random) else { return nil }
                let position = Int64.random(in: 0..<range.upperBound, using: &random)
                return IndexedKeyframe(time: position, position: position)
            }
            let input = "seed \(seed): \(fileSize) bytes, spacing \(limits.densestSpacing), largest \(limits.largestSegment)"

            #expect(samples.count <= fileSize, "\(input): \(samples.count) samples")
            #expect(samples.allSatisfy { !$0.searched.isEmpty && (0..<fileSize).contains($0.searched.lowerBound) && $0.searched.upperBound <= fileSize }, "\(input)")
            let read = samples.map { $0.searched.lowerBound..<Self.readThrough($0) }.sorted { $0.lowerBound < $1.lowerBound }
            #expect(zip(read, read.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound }, "\(input): \(read)")
        }
    }

    @Test("a sampled file is listed from its first keyframe on, with no two listed keyframes further apart than the spacing and one keyframe interval")
    func samplesAreSpreadOverTheFile() throws {
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let layout = Layout.random(using: &random)
            guard !layout.keyframes.isEmpty else { continue }
            let listed = try Self.sampled(layout.fileSize, layout.limits, answer: layout.keyframe(in:))
                .compactMap(\.keyframe).listed().map(\.position)

            #expect(listed.first == layout.keyframes.first, "seed \(seed): \(layout)")
            let widest = Self.gaps(between: listed, fileSize: layout.fileSize).max() ?? 0
            #expect(widest <= layout.limits.densestSpacing + layout.widestInterval, "seed \(seed): \(layout): a gap of \(widest)")
        }
    }

    @Test("once the time is up, sampling goes on only until no segment is larger than the largest, where a keyframe lets one be cut")
    func samplingPastItsTimeStopsAtTheLargestSegment() throws {
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let layout = Layout.random(using: &random)
            guard !layout.keyframes.isEmpty else { continue }
            let hurriedFrom = Int.random(in: 1...6, using: &random)
            let samples = Self.sampled(
                layout.fileSize, layout.limits, hurriedFrom: hurriedFrom, answer: layout.keyframe(in:))
            let largest = layout.limits.largestSegment

            for index in samples.indices.dropFirst(hurriedFrom) {
                let range = samples[index].searched
                let found = samples[..<index].compactMap(\.keyframe?.position).sorted()
                let before = try #require(found.last { $0 < range.lowerBound })
                let after = found.first { $0 >= range.upperBound } ?? layout.fileSize
                #expect(after - before > largest, "seed \(seed): \(layout): sample \(index) at \(range)")
            }
            let listed = try samples.compactMap(\.keyframe).listed().map(\.position)
            let widest = Self.gaps(between: listed, fileSize: layout.fileSize).max() ?? 0
            #expect(widest <= max(largest, layout.limits.densestSpacing + layout.widestInterval), "seed \(seed): \(layout): a gap of \(widest)")
        }
    }

    /// A segment also holds what the sample that closes it reads through to reach its keyframe.
    /// A cut leaves room for the longest such read before it, or for half the largest segment
    /// where that read is longer.
    @Test("once the time is up, a cut leaves room for the longest read to a keyframe before it, so the segment it closes is no larger than the largest")
    func cutLeavesRoomForTheReadToAKeyframe() throws {
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let layout = Layout.random(using: &random)
            guard !layout.keyframes.isEmpty else { continue }
            let hurriedFrom = Int.random(in: 1...6, using: &random)
            let samples = Self.sampled(
                layout.fileSize, layout.limits, hurriedFrom: hurriedFrom, answer: layout.keyframe(in:))
            let largest = layout.limits.largestSegment

            for index in samples.indices.dropFirst(hurriedFrom) {
                guard let keyframe = samples[index].keyframe else { continue }
                let start = samples[index].searched.lowerBound
                let before = samples[..<index]
                let longestRead = before.compactMap { sample in
                    sample.keyframe.map { $0.position - sample.searched.lowerBound }
                }.max() ?? 0
                guard keyframe.position - start < min(longestRead, largest / 2) else { continue }
                let stretchStart = before.filter { $0.searched.lowerBound < start }.map(Self.readThrough).max() ?? 0
                let closed = keyframe.position - stretchStart + 1
                #expect(closed <= largest, "seed \(seed): \(layout): sample \(index) at \(start) closed a segment of \(closed)")
            }
        }
    }

    /// Which keeps the segments few: a stretch is cut a segment at a time, not in halves.
    @Test("a sample starts no further than the largest segment past the keyframe before it")
    func sampleCutsOffAtMostTheLargestSegment() throws {
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let layout = Layout.random(using: &random)
            guard !layout.keyframes.isEmpty else { continue }
            let samples = Self.sampled(
                layout.fileSize, layout.limits, hurriedFrom: Int.random(in: 1...6, using: &random),
                answer: layout.keyframe(in:))

            for index in samples.indices.dropFirst() {
                let start = samples[index].searched.lowerBound
                let before = try #require(samples[..<index].compactMap(\.keyframe?.position).filter { $0 < start }.max())
                #expect(start - (before + 1) <= layout.limits.largestSegment, "seed \(seed): \(layout): sample \(index) at \(start)")
            }
        }
    }

    @Test("keyframes found out of file order, or twice, are listed in file order, each once")
    func keyframesAreListedInFileOrderOnce() throws {
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let positions = Layout.random(using: &random).keyframes
            let keyframes = positions.map { IndexedKeyframe(time: $0 * 3, position: $0) }
            let found = keyframes.flatMap { keyframe in
                Array(repeating: keyframe, count: Int.random(in: 0...3, using: &random))
            }.shuffled(using: &random)
            let distinct = keyframes.filter(found.contains)

            #expect(try found.listed() == distinct, "seed \(seed): \(found.count) found")
            #expect(try found.listed().listed() == distinct, "seed \(seed)")
        }
    }

    /// The naive rule: in file order, a keyframe timed before one before it refuses the file, and
    /// one timed as the keyframe before it adds nothing.
    @Test("keyframes whose times go back are refused, with the last time before they do")
    func timesThatGoBackAreRefused() {
        let second: Int64 = 1_000_000_000
        for seed in 0..<UInt64(Self.cases) {
            var random = SeededGenerator(seed: seed)
            let count = Int.random(in: 1...40, using: &random)
            let goesBack = Bool.random(using: &random)
            var time = Int64.random(in: -5...5, using: &random) * second
            let inFileOrder = (0..<count).map { place in
                time += goesBack && Int.random(in: 0..<8, using: &random) == 0
                    ? -Int64.random(in: 1...3 * second, using: &random)
                    // Half seconds, so two keyframes often share a time.
                    : Int64.random(in: 0...4, using: &random) * second / 2
                return IndexedKeyframe(time: time, position: Int64(place) * 1000 + Int64.random(in: 0..<1000, using: &random))
            }
            var expected: Result<[IndexedKeyframe], BridgeRefusal> = .success([])
            var latest = Int64.min
            for keyframe in inFileOrder {
                guard case .success(let kept) = expected else { break }
                if keyframe.time < latest {
                    expected = .failure(.timestampsRestart(after: Int((latest - inFileOrder[0].time) / second)))
                } else if keyframe.time > latest {
                    expected = .success(kept + [keyframe])
                }
                latest = max(latest, keyframe.time)
            }

            let listed = Result { () throws(BridgeRefusal) in try inFileOrder.shuffled(using: &random).listed() }
            #expect(listed == expected, "seed \(seed): times \(inFileOrder.map { $0.time / 1_000_000 }) ms")
        }
    }
}

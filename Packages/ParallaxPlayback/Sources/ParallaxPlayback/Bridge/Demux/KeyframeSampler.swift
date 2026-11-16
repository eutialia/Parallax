/// Chooses where to sample a file that has no index and is too large to read whole. A sample
/// reads a range of the file from its start to the first video keyframe, so it also shows that
/// the bytes it read through hold none. What no sample has read through is a stretch, and a
/// segment runs from the keyframe before a stretch to the next keyframe found after it.
///
/// The stretch with the largest segment is cut first: a largest segment off its start while
/// half of it is wider than one, then in half. A file is so cut into the fewest segments it
/// can be held in before any is made smaller: over a share, halving alone took 256 samples and
/// 19 s of a 20 GB file where 162 samples took 6 s.
struct KeyframeSampler: Sendable {
    struct Limits: Sendable {
        /// A stretch this wide or narrower is not sampled.
        var densestSpacing: Int64 = 8 << 20
        /// A segment is held in memory while it is written. 102 MB is the largest played on a
        /// device so far. Once the time for sampling is up, only a stretch whose segment is
        /// larger than this is sampled.
        var largestSegment: Int64 = 256 << 20

        static let standard = Limits()
    }

    /// What a read of `searched` came to: the first video keyframe that starts in it, or nil
    /// for none.
    struct Sample: Sendable {
        let searched: Range<Int64>
        let keyframe: IndexedKeyframe?

        /// A sample reads through at least one byte, whatever the reader answers, so sampling
        /// ends.
        fileprivate var readThroughTo: Int64 {
            max(searched.lowerBound + 1, keyframe.map { $0.position + 1 } ?? searched.upperBound)
        }
    }

    let fileSize: Int64
    let limits: Limits

    /// The range to sample next, nil when the sampling is done. It ends where a sample has
    /// read already. The first is the whole file: every read of the first segment starts at
    /// the file's first keyframe.
    func nextRange(after samples: [Sample], timeIsUp: Bool) -> Range<Int64>? {
        guard !samples.isEmpty else { return 0..<fileSize }
        let worthSampling = stretches(between: samples).filter {
            $0.unread.count > limits.densestSpacing && !(timeIsUp && $0.segment <= limits.largestSegment)
        }
        guard let largest = worthSampling.max(by: { $0.segment < $1.segment }) else { return nil }
        // A segment also holds what the sample after its stretch reads through to reach a
        // keyframe, so a cut leaves room for the longest such read so far.
        let readToAKeyframe = samples.compactMap { sample in
            sample.keyframe.map { $0.position - sample.searched.lowerBound }
        }.max() ?? 0
        let cut = max(limits.largestSegment - readToAKeyframe, limits.largestSegment / 2)
        return largest.unread.lowerBound + min(Int64(largest.unread.count / 2), cut)..<largest.unread.upperBound
    }

    private struct Stretch {
        /// From just after a keyframe found to where a sample started.
        let unread: Range<Int64>
        /// The position of the next keyframe found, or the file's size.
        let segmentEnd: Int64

        var segment: Int64 { segmentEnd - unread.lowerBound + 1 }
    }

    private func stretches(between samples: [Sample]) -> [Stretch] {
        let inFileOrder = samples.sorted { $0.searched.lowerBound < $1.searched.lowerBound }
        let readThroughTo = inFileOrder.reduce(into: [Int64]()) { ends, sample in
            ends.append(max(ends.last ?? 0, sample.readThroughTo))
        }
        let nextStarts = inFileOrder.dropFirst().map(\Sample.searched.lowerBound) + [fileSize]
        let found = samples.compactMap(\.keyframe?.position).sorted()
        return zip(readThroughTo, nextStarts).filter { $0 < $1 }.map { unread in
            Stretch(unread: unread.0..<unread.1, segmentEnd: found.first { $0 >= unread.1 } ?? fileSize)
        }
    }
}

extension [IndexedKeyframe] {
    /// Keyframes a read of the file came by, as the list spans are cut from: in file order,
    /// each once. Throws `BridgeRefusal.timestampsRestart` where a keyframe's time is before
    /// the last one's, as in a file joined from two recordings: a span is bounded by its
    /// keyframes' times.
    func listed() throws(BridgeRefusal) -> [IndexedKeyframe] {
        var listed: [IndexedKeyframe] = []
        for keyframe in sorted(by: { $0.position < $1.position }) {
            guard let last = listed.last else {
                listed.append(keyframe)
                continue
            }
            if keyframe.time < last.time {
                throw .timestampsRestart(after: Int((last.time - listed[0].time) / 1_000_000_000))
            }
            if keyframe.time > last.time, keyframe.position > last.position { listed.append(keyframe) }
        }
        return listed
    }
}

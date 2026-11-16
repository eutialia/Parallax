import Testing
@testable import ParallaxPlayback

@Suite("KeyframeSampler")
struct KeyframeSamplerTests {

    /// Samples a file known only by where its keyframes are, as the demuxer samples a real one.
    /// The time is up once `timeIsUpAfter` samples are taken. `found` stands for the reader.
    private static func sample(
        fileSize: Int64, limits: KeyframeSampler.Limits, timeIsUpAfter: Int = .max,
        found: (Range<Int64>) -> Int64?
    ) throws -> [KeyframeSampler.Sample] {
        let sampler = KeyframeSampler(fileSize: fileSize, limits: limits)
        var samples: [KeyframeSampler.Sample] = []
        while let range = sampler.nextRange(after: samples, timeIsUp: samples.count >= timeIsUpAfter) {
            try #require(samples.count < 10_000, "the sampling does not end")
            samples.append(.init(searched: range, keyframe: found(range).map { IndexedKeyframe(time: $0, position: $0) }))
        }
        return samples
    }

    private static func sample(
        fileSize: Int64, keyframesAt positions: [Int64], limits: KeyframeSampler.Limits, timeIsUpAfter: Int = .max
    ) throws -> [KeyframeSampler.Sample] {
        try sample(fileSize: fileSize, limits: limits, timeIsUpAfter: timeIsUpAfter) { range in
            positions.first { range.contains($0) }
        }
    }

    private static func listed(_ samples: [KeyframeSampler.Sample]) throws -> [Int64] {
        try samples.compactMap(\.keyframe).listed().map(\.position)
    }

    private static func widestGap(in positions: [Int64], fileSize: Int64) -> Int64 {
        zip(positions, positions.dropFirst() + [fileSize]).map { $1 - $0 }.max() ?? fileSize
    }

    private static func bytesRead(by samples: [KeyframeSampler.Sample]) -> Int64 {
        samples.reduce(0) { $0 + ($1.keyframe?.position ?? $1.searched.upperBound) - $1.searched.lowerBound }
    }

    private static let everyTen = Array(stride(from: Int64(5), to: 10_000, by: 10))

    @Test("a sampled file is listed from its first keyframe on, with no two listed keyframes further apart than the spacing and one keyframe interval")
    func samplesAreSpreadOverTheFile() throws {
        let samples = try Self.sample(
            fileSize: 10_000, keyframesAt: Self.everyTen, limits: .init(densestSpacing: 500, largestSegment: 5000))
        let listed = try Self.listed(samples)

        #expect(listed.first == 5)
        #expect(Self.widestGap(in: listed, fileSize: 10_000) <= 511)
        #expect(samples.count <= 32)
    }

    @Test("a long stretch with no keyframe is read through once, and the keyframe after it is listed once")
    func stretchWithNoKeyframeIsReadOnce() throws {
        let samples = try Self.sample(
            fileSize: 10_000, keyframesAt: [5, 9000], limits: .init(densestSpacing: 500, largestSegment: 5000))

        #expect(try Self.listed(samples) == [5, 9000])
        #expect(Self.bytesRead(by: samples) <= 10_000)
    }

    @Test("once the time is up, sampling goes on only until no segment is larger than the largest")
    func samplingPastItsTimeStopsAtTheLargestSegment() throws {
        let limits = KeyframeSampler.Limits(densestSpacing: 100, largestSegment: 2000)
        let hurried = try Self.sample(fileSize: 10_000, keyframesAt: Self.everyTen, limits: limits, timeIsUpAfter: 1)
        let unhurried = try Self.sample(fileSize: 10_000, keyframesAt: Self.everyTen, limits: limits)

        #expect(hurried.count <= 6)
        #expect(Self.widestGap(in: try Self.listed(hurried), fileSize: 10_000) <= 2000)
        #expect(Self.widestGap(in: try Self.listed(unhurried), fileSize: 10_000) <= 111)
    }

    @Test("keyframes far apart still leave no segment larger than the largest, where a keyframe lets one be cut")
    func segmentsStayUnderTheLargestWithKeyframesFarApart() throws {
        let samples = try Self.sample(
            fileSize: 10_000, keyframesAt: Array(stride(from: Int64(5), to: 10_000, by: 700)),
            limits: .init(densestSpacing: 100, largestSegment: 2000), timeIsUpAfter: 1)

        #expect(Self.widestGap(in: try Self.listed(samples), fileSize: 10_000) <= 2000)
        #expect(samples.count <= 10)
    }

    @Test("a file with no video keyframe is sampled once, all of it")
    func fileWithNoKeyframeIsSampledOnce() throws {
        let samples = try Self.sample(fileSize: 10_000, keyframesAt: [], limits: .standard)

        #expect(samples.map(\.searched) == [0..<10_000])
    }

    @Test("a reader that answers every sample with a keyframe before its start does not keep the sampling going")
    func keyframeBeforeItsSampleEndsTheSampling() throws {
        let samples = try Self.sample(
            fileSize: 10_000, limits: .init(densestSpacing: 100, largestSegment: 2000)) { _ in 0 }

        #expect(try Self.listed(samples) == [0])
    }

    @Test("keyframes whose times go back are refused, with the last time before they do")
    func timesThatGoBackAreRefused() {
        let second: Int64 = 1_000_000_000
        let found = [(0, 2), (100, 6), (200, 10), (300, 4), (400, 8)].map {
            IndexedKeyframe(time: Int64($0.1) * second, position: Int64($0.0))
        }

        #expect(throws: BridgeRefusal.timestampsRestart(after: 8)) {
            _ = try found.listed()
        }
    }

    @Test("keyframes found out of file order, or twice, are listed in file order, each once")
    func keyframesAreListedInFileOrderOnce() throws {
        let found = [300, 100, 300, 200, 100].map { IndexedKeyframe(time: Int64($0), position: Int64($0)) }

        #expect(try found.listed().map(\.position) == [100, 200, 300])
    }
}

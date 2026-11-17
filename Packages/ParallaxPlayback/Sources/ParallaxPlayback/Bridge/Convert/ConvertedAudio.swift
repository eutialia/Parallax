import Foundation

/// An audio stream delivered as FLAC: decoded, and encoded again segment by segment.
struct ConvertedAudio: Sendable {
    /// The RFC 6381 string a playlist's `CODECS` carries.
    static let codec = "fLaC"

    let stream: DemuxedStream
    /// Nanoseconds: where the first sample the stream decodes to is, in the file's own time.
    let start: Int64
    let sampleRate: Int
    let channelCount: Int
    /// Where a decoded frame can start: the stream's second frame, and every step of the
    /// longest length that divides those of the opening's frames after the first. A stream's
    /// first frame is whatever is left of it: 47 samples of an MP3's 1152. Nil for an opening
    /// that decodes to one frame.
    let sourceGrid: MediaClock.Grid?
    /// The FLAC stream as the MP4 muxer describes it.
    let encoded: CodecParameters
    /// The stream's first FLAC frame, which the init segment is described by.
    let firstFrame: [MediaPacket]

    /// Bits a second of the samples themselves, which no FLAC frame holds more than.
    var sampleBitrate: Int { sampleRate * channelCount * 24 }

    /// Nil for a stream this build has no decoder for, one that decodes to more channels than
    /// FLAC carries, and one the opening's packets decode to nothing of.
    init?(_ stream: DemuxedStream, openingWith packets: [MediaPacket]) {
        guard let decoder = try? AudioDecoder(stream.parameters) else { return nil }
        var decoded: [DecodedAudio] = []
        for packet in packets { try? decoder.decode(packet) { decoded.append($0) } }
        guard let first = decoded.first, (1...8).contains(first.channelCount) else { return nil }
        let format = (sampleRate: first.sampleRate, channelCount: first.channelCount)
        let frames = decoded.filter { $0.sampleRate == format.sampleRate && $0.channelCount == format.channelCount }
        var run = SampleRun(sampleRate: format.sampleRate, tick: stream.tick)
        for frame in frames {
            if run.isPlaced { break }
            run.add(frame, timed: run.agrees(with: frame.time))
        }
        guard let start = run.start,
              let encoder = try? FLACEncoder(sampleRate: format.sampleRate, channelCount: format.channelCount)
        else { return nil }
        var encodedFrames: [(data: Data, length: Int64)] = []
        try? encoder.encode(first.samples) { encodedFrames.append(($0, $1)) }
        try? encoder.finish { encodedFrames.append(($0, $1)) }
        guard let flac = encodedFrames.first else { return nil }

        self.stream = stream
        self.start = start
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        let step = frames.dropFirst().reduce(0) { Self.greatestCommonDivisor($0, $1.frameCount) }
        sourceGrid = step > 0
            ? .init(anchor: start + run.nanoseconds(of: first.frameCount), step: Int64(step), tolerance: stream.tick)
            : nil
        encoded = encoder.parameters
        firstFrame = [
            MediaPacket(
                stream: stream.index, presentationTime: start,
                duration: flac.length * 1_000_000_000 / Int64(format.sampleRate), isKeyframe: true, data: flac.data)
        ]
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : greatestCommonDivisor(b, a % b)
    }

    func rendition(origin: Int64) -> Rendition {
        Rendition(
            stream: stream, delivery: .audio(self),
            clock: MediaClock(timescale: Int64(sampleRate), origin: origin, grid: nil))
    }
}

/// Decoded frames that follow one another with no gap, and where the first of them starts.
///
/// A frame is placed by the samples decoded before it, from a start the times of the run's
/// first frames agree on, and never by its own time alone. A container times a frame to its
/// own tick, and a Matroska file's millisecond is longer than a TrueHD frame of 40 samples:
/// two frames in a row can carry one time. And a Vorbis frame after a change of frame length
/// is timed 9 ms from where its samples are.
struct SampleRun {
    /// Timed frames the start is taken from.
    static let framesPlacedBy = 32
    /// Frames in a row, each timed off the run, that end it. One alone is the container's
    /// timing of that frame.
    static let framesEndingARun = 3

    private let sampleRate: Double
    /// Nanoseconds a frame's time may be from where the run puts it.
    private let tolerance: Double
    private var frameCount = 0
    /// Nanoseconds: where each timed frame says the run starts.
    private var starts: [Double] = []

    /// `tick` is the nanoseconds in one unit of the container's clock for the stream.
    init(sampleRate: Int, tick: Int64) {
        self.sampleRate = Double(sampleRate)
        tolerance = Double(max(2 * tick, 1_000_000))
    }

    /// Whether the run's start is settled: later frames no longer move it.
    var isPlaced: Bool { starts.count >= Self.framesPlacedBy }

    /// Nanoseconds: the middle one of the starts the frames say, which a few frames timed off
    /// the run do not move. Nil for a run with no timed frame.
    var start: Int64? {
        starts.isEmpty ? nil : Int64(starts.sorted()[starts.count / 2].rounded())
    }

    /// False for a frame timed where the run does not put it: the stream stopped for a while
    /// or went back, or the container timed this one frame off. A frame with no time follows
    /// the one before it.
    func agrees(with time: Int64?) -> Bool {
        guard let time, let start else { return true }
        return abs(startSaid(by: time) - Double(start)) <= tolerance
    }

    /// `timed` false leaves the frame's time out of the run's start.
    mutating func add(_ frame: DecodedAudio, timed: Bool = true) {
        if timed, let time = frame.time, !isPlaced { starts.append(startSaid(by: time)) }
        frameCount += frame.frameCount
    }

    /// How long `frameCount` sample frames last.
    func nanoseconds(of frameCount: Int) -> Int64 {
        Int64((Double(frameCount) * 1_000_000_000 / sampleRate).rounded())
    }

    private func startSaid(by time: Int64) -> Double {
        Double(time) - Double(frameCount) * 1_000_000_000 / sampleRate
    }
}

/// One segment of a converted audio rendition in the making: the stream's packets in, FLAC
/// frames out.
///
/// The segment holds the samples whose ticks are in `ticks`, so neighboring segments share no
/// sample and drop none. The read starts before the segment and runs past its end: a decoder
/// needs packets before the first sample it gets right, and may give a packet's samples only
/// when handed a later one. Where the stream has no samples for a while, the segment has
/// silence.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class AudioConversion: PacketSink {
    private let clock: MediaClock
    private let ticks: Range<Int64>
    private let tick: Int64
    private let sampleRate: Int
    private let channelCount: Int
    private let timer: ConversionTimer
    private let cancelled: () -> Bool
    private let take: (Data, _ tick: Int64, _ length: Int64) throws -> Void
    private let decoder: AudioDecoder
    private let encoder: FLACEncoder

    private var run: SampleRun
    /// The run's frames, until it is placed.
    private var unplaced: [DecodedAudio] = []
    private var runIsPlaced = false
    /// The latest frames, each timed off the run: the start of another run, or frames the
    /// container timed badly.
    private var timedOffTheRun: [DecodedAudio] = []
    /// The tick after the last sample decoded and placed.
    private var decodedUntil = Int64.min
    /// The tick after the last sample encoded. Nil for a file's first segment before its first
    /// sample, which is wherever the stream starts.
    private var encodedUntil: Int64?
    /// The tick of the next FLAC frame the encoder gives.
    private var frameStart: Int64?
    private var framesHanded: Int64 = 0

    /// `ticks` are the segment's on the rendition's clock: from `.min` for the file's first
    /// segment, to `.max` for the stream's last. `take` is handed each FLAC frame with the
    /// tick it starts at and the ticks it lasts.
    init(
        _ audio: ConvertedAudio, of rendition: Rendition, ticks: Range<Int64>,
        stopwatch: @escaping () -> () -> Duration, cancelled: @escaping () -> Bool,
        into take: @escaping (Data, _ tick: Int64, _ length: Int64) throws -> Void
    ) throws {
        clock = rendition.packetClock
        self.ticks = ticks
        tick = audio.stream.tick
        sampleRate = audio.sampleRate
        channelCount = audio.channelCount
        timer = ConversionTimer(stopwatch)
        self.cancelled = cancelled
        self.take = take
        decoder = try AudioDecoder(audio.stream.parameters)
        encoder = try FLACEncoder(sampleRate: audio.sampleRate, channelCount: audio.channelCount)
        run = SampleRun(sampleRate: audio.sampleRate, tick: audio.stream.tick)
        encodedUntil = ticks.lowerBound == .min ? nil : ticks.lowerBound
    }

    var isCancelled: Bool { cancelled() }

    /// Whether the samples up to the segment's end are decoded.
    var isSatisfied: Bool { decodedUntil >= ticks.upperBound }

    /// Seconds of the segment for each second its decoding and encoding took. Nil for a
    /// segment with no samples, and on a clock that does not move.
    var speed: Double? { timer.speed(converting: Double(framesHanded) / Double(sampleRate)) }

    func accept(_ packet: MediaPacket) throws {
        try timer.work { try decoder.decode(packet, into: place) }
    }

    /// The rest of the segment, once the read has returned.
    func finish() throws {
        try timer.work {
            // The read returned short of the segment's end: the stream has no more packets.
            if !isSatisfied { try decoder.finish(into: place) }
            try continueRun(with: timedOffTheRun)
            try placeUnplaced()
            if let encodedUntil, ticks.upperBound != .max, encodedUntil < ticks.upperBound {
                try encodeSilence(until: ticks.upperBound)
            }
            try encoder.finish(into: hand)
        }
    }

    private func place(_ frame: DecodedAudio) throws {
        guard frame.channelCount == channelCount, frame.sampleRate == sampleRate else { return }
        guard run.agrees(with: frame.time) else {
            timedOffTheRun.append(frame)
            if timedOffTheRun.count == SampleRun.framesEndingARun {
                try placeUnplaced()
                run = SampleRun(sampleRate: sampleRate, tick: tick)
                runIsPlaced = false
                try continueRun(with: timedOffTheRun)
            }
            return
        }
        try continueRun(with: timedOffTheRun, timed: false)
        try continueRun(with: [frame])
    }

    private func continueRun(with frames: [DecodedAudio], timed: Bool = true) throws {
        timedOffTheRun = []
        for frame in frames {
            run.add(frame, timed: timed)
            if runIsPlaced {
                try encode(frame)
            } else {
                unplaced.append(frame)
                if run.isPlaced { try placeUnplaced() }
            }
        }
    }

    private func placeUnplaced() throws {
        defer { unplaced = [] }
        guard !runIsPlaced, let start = run.start else { return }
        // The run's second frame is the one the grid places: its first may be a stream's first.
        let first = unplaced.first?.frameCount ?? 0
        decodedUntil = clock.ticks(at: start + run.nanoseconds(of: first)) - Int64(first)
        runIsPlaced = true
        for frame in unplaced { try encode(frame) }
    }

    /// The frame's samples that are the segment's and not yet encoded, after silence for the
    /// ticks between them and the last encoded.
    private func encode(_ frame: DecodedAudio) throws {
        let start = decodedUntil
        decodedUntil += Int64(frame.frameCount)
        let from = max(start, encodedUntil ?? ticks.lowerBound), to = min(decodedUntil, ticks.upperBound)
        guard from < to else { return }
        if encodedUntil != nil { try encodeSilence(until: from) }
        frameStart = frameStart ?? from
        try encoder.encode(frame.samples[Int(from - start) * channelCount..<Int(to - start) * channelCount], into: hand)
        encodedUntil = to
    }

    private func encodeSilence(until end: Int64) throws {
        guard var from = encodedUntil else { return }
        frameStart = frameStart ?? from
        while from < end {
            let count = min(end - from, Int64(sampleRate))
            try encoder.encode(repeatElement(0, count: Int(count) * channelCount), into: hand)
            from += count
        }
        encodedUntil = end
    }

    private func hand(_ data: Data, lasting length: Int64) throws {
        guard let start = frameStart else { return }
        try timer.hand { try take(data, start, length) }
        frameStart = start + length
        framesHanded += length
    }
}

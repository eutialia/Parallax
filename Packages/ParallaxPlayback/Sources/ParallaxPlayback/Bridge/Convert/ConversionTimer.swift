/// Times a converting sink's own work: its decoding and encoding, less the time spent handing
/// a sample on, which waits for AVPlayer to take it.
///
/// Lives on one thread: the demuxer's queue that reads the segment.
final class ConversionTimer {
    private let stopwatch: () -> () -> Duration
    private var working = Duration.zero
    private var handing = Duration.zero

    init(_ stopwatch: @escaping () -> () -> Duration) {
        self.stopwatch = stopwatch
    }

    /// `body` may hand samples on through `hand`.
    func work(_ body: () throws -> Void) rethrows {
        let handedBefore = handing
        let elapsed = stopwatch()
        defer { working += elapsed() - (handing - handedBefore) }
        try body()
    }

    func hand(_ body: () throws -> Void) rethrows {
        let elapsed = stopwatch()
        defer { handing += elapsed() }
        try body()
    }

    /// Seconds of media for each second of work. Nil for no media, and on a clock that does
    /// not move.
    func speed(converting seconds: Double) -> Double? {
        let spent = working / .seconds(1)
        return seconds > 0 && spent > 0 ? seconds / spent : nil
    }
}

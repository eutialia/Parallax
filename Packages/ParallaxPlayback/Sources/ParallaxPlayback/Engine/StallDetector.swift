import Foundation

/// Pure stall-detection counter for the VLC progress poll. `VLCMediaPlayer.isPlaying` reflects
/// *intent*, not frames (VideoLAN VLCKit#578) — when the network dies mid-stream it keeps reading
/// `true` while the clock is frozen, so the poll would emit `.playing` beats over a dead stream
/// forever. The honest signal is progress on TWO independent axes: the playback clock (`player.time`)
/// and the demux byte counter (`statistics.demuxReadBytes`, already read for the duration estimate).
///
/// Semantics (each decision unit-tested):
/// - **Both frozen** across `tripThreshold` consecutive polls → a real stall (trips).
/// - **Bytes advancing, time frozen** → network alive, the read-ahead buffer is refilling while the
///   decoder starves; let it recover — NOT a stall.
/// - **Time advancing, bytes frozen** → playing out of buffer / draining the EOF tail — NOT a stall.
///
/// Any advance on either axis resets the counter. Pure value type: exhaustively testable without a
/// live decode. The engine owns recovery/arm/disarm side effects; this only answers "stalled now?".
struct StallDetector {
    /// Consecutive frozen-everything polls before a stall trips. 6 × the 500ms poll = 3s frozen —
    /// long enough that a keyframe-boundary hitch or a GOP-sized demux gap doesn't false-positive,
    /// short enough to surface the honest buffering scrim well before the 45s `StallWatchdog` failure.
    static let tripThreshold = 6

    private var lastTimeMs: Int32?
    private var lastReadBytes: Int?
    private var frozenPolls = 0

    /// Feed one poll sample. Returns `true` once `tripThreshold` consecutive samples have shown BOTH
    /// the clock and the demux byte counter unchanged (and stays `true` while the freeze persists).
    /// The first sample establishes the baseline and never trips.
    mutating func observe(timeMs: Int32, readBytes: Int) -> Bool {
        defer {
            lastTimeMs = timeMs
            lastReadBytes = readBytes
        }
        guard let lastTimeMs, let lastReadBytes else { return false }
        let frozen = timeMs == lastTimeMs && readBytes == lastReadBytes
        frozenPolls = frozen ? frozenPolls + 1 : 0
        return frozenPolls >= Self.tripThreshold
    }

    /// Drop the baseline and counter so a fresh detection window starts clean — called on pause,
    /// seek, and load (any point where the next sample must not be compared against a stale one).
    mutating func reset() {
        lastTimeMs = nil
        lastReadBytes = nil
        frozenPolls = 0
    }
}

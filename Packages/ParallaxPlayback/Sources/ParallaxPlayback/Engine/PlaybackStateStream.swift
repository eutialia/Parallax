import Foundation

/// The `(stream, continuation)` pair every `PlaybackEngine` publishes its beats on,
/// pre-seeded with an `.idle` stamped `PlaybackSessionID.none` — no session has been opened
/// yet, so no consumer holding one adopts it. Both `AVKitEngine` and `VLCKitEngine` construct their
/// `state`/`continuation` stored properties from this single factory — the buffering
/// policy and its rationale used to be duplicated verbatim in each engine's `init`.
enum PlaybackStateStream {
    /// Bounded so a wedged consumer can't grow the buffer without limit.
    /// `.bufferingNewest` keeps the freshest beats — the latest position plus any
    /// terminal `.ready`/`.ended`/`.failed` (nothing follows those, so they're never the
    /// dropped-oldest) — and 32 ≈ 16s of 0.5s position beats, far beyond what the
    /// MainActor consumer ever queues. It only sheds stale intermediate positions
    /// under a real stall, which the next beat supersedes anyway.
    static func makeStream() -> (
        stream: AsyncStream<PlaybackBeat>,
        continuation: AsyncStream<PlaybackBeat>.Continuation
    ) {
        let (stream, continuation) = AsyncStream<PlaybackBeat>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation.yield(PlaybackBeat(session: .none, state: .idle))
        return (stream, continuation)
    }
}

import Foundation

/// The `(stream, continuation)` pair every `PlaybackEngine` publishes its beats on,
/// pre-seeded with `.idle`. Both `AVKitEngine` and `VLCKitEngine` construct their
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
        stream: AsyncStream<PlaybackState>,
        continuation: AsyncStream<PlaybackState>.Continuation
    ) {
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation.yield(.idle)
        return (stream, continuation)
    }
}

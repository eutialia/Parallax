import CoreMedia
import Foundation
import ParallaxPlayback

/// A position-carrying beat, flattened to the facts the seek-settle contract is about
/// (see `PlaybackState`). Non-position states map to nil.
public struct PositionBeat: Equatable, Sendable {
    public let seconds: Double
    public let provenance: PositionProvenance
    public let isBuffering: Bool

    public init?(_ state: PlaybackState) {
        switch state {
        case .playing(let position, _, _, let provenance), .paused(let position, _, _, let provenance):
            (seconds, self.provenance, isBuffering) = (CMTimeGetSeconds(position), provenance, false)
        case .buffering(let position, _, _, let provenance):
            (seconds, self.provenance, isBuffering) = (CMTimeGetSeconds(position), provenance, true)
        default:
            return nil
        }
    }
}

/// Collects an engine's beats AS THEY LAND, so a test can wait for the n-th one instead of
/// sleeping — the post-teardown drain the older suites use can only look at the past, and the
/// seek-settle contract is about *which* beat carries which provenance, not just the final one.
/// One consumer task, which is the `state` stream's contract.
@MainActor
public final class PositionBeatLog {
    public private(set) var beats: [PositionBeat] = []
    /// The terminal failure the engine reported, if one arrived. Recorded here rather than by a
    /// second collector because `state` has exactly ONE consumer: a test that needs both the
    /// beat history and the failure that ends it cannot iterate the stream twice.
    public private(set) var failure: PlaybackError?
    private var task: Task<Void, Never>?

    public init(_ engine: any PlaybackEngine) {
        let stream = engine.state
        task = Task { @MainActor [weak self] in
            for await state in stream {
                if case .failed(let error) = state { self?.failure = error }
                guard let beat = PositionBeat(state) else { continue }
                self?.beats.append(beat)
            }
        }
    }

    /// Every beat at or past `seconds` — for a seek away from a lower position, that is the
    /// seek's own echo and everything published after it, with the pre-seek beats filtered out.
    public func from(_ seconds: Double) -> [PositionBeat] { beats.filter { $0.seconds >= seconds } }

    public func stop() { task?.cancel() }
}

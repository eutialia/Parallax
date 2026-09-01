import Foundation

/// Which media a beat belongs to. An engine is reloadable in place — the transcode
/// re-anchor and the track switch keep the engine, its stream and its continuation so the
/// video layer survives the swap — so "engine" is not a fine enough identity: the beats of
/// the media being replaced and the beats of its replacement travel the same stream.
///
/// Opaque and monotonic WITHIN one engine, minted by `load()`. Comparing ids across two
/// engines is meaningless; the consumer answers that question by comparing the engines.
public struct PlaybackSessionID: Hashable, Sendable, CustomStringConvertible {
    private let raw: UInt64

    /// Before any `load()`: what an engine's seeded `.idle` carries. Never equal to a
    /// session `load()` opened, so a consumer holding a real session drops it.
    public static let none = PlaybackSessionID(raw: 0)

    private init(raw: UInt64) { self.raw = raw }

    /// The next session this engine will open. `&+` because wrapping after 2^64 loads is a
    /// theoretical concern and trapping in a media player is not.
    public func next() -> PlaybackSessionID { PlaybackSessionID(raw: raw &+ 1) }

    public var description: String { raw == 0 ? "session:none" : "session:\(raw)" }
}

/// One element of an engine's state stream: a `PlaybackState` and the session that
/// published it.
///
/// The stamp is applied at YIELD time, by the engine, from the session the publishing
/// callback was installed for — which is what makes it survive buffering and MainActor
/// hops. Every other way of asking "is this beat still mine?" is a race the consumer has to
/// win (a flag raised for the duration of a reload is cleared on the reload's timeline,
/// while the beats it was meant to swallow are drained on the consumer's).
public struct PlaybackBeat: Sendable {
    public let session: PlaybackSessionID
    public let state: PlaybackState

    public init(session: PlaybackSessionID, state: PlaybackState) {
        self.session = session
        self.state = state
    }
}

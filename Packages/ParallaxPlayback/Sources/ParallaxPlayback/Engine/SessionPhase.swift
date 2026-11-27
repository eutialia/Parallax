/// The session an engine last opened, and whether it is still publishing.
///
/// Every beat is stamped with the session of the callback that produced it, and only the live
/// session's beats are published. That is what a reload needs: it keeps the player, the stream
/// and the continuation and swaps only the item underneath them, so a callback of the item it
/// replaced can still fire.
///
/// A terminal beat (`.ended`, `.failed`) ends the session in place. The app does not tear the
/// engine down on `.failed`, so the item and its observers outlive it, and AVPlayer can still
/// recover underneath the error scrim: a link back after the stall deadline, an HLS item ready
/// after the load deadline. Nothing from a recovery is the session's to publish. Only the next
/// load opens a live one.
enum SessionPhase: Equatable, Sendable {
    case live(PlaybackSessionID)
    case terminated(PlaybackSessionID)

    var id: PlaybackSessionID {
        switch self {
        case .live(let id), .terminated(let id): id
        }
    }

    /// The phase after `state` is published from `session`, or nil when it is not published.
    func publishing(_ state: PlaybackState, from session: PlaybackSessionID) -> SessionPhase? {
        guard self == .live(session) else { return nil }
        switch state {
        case .ended, .failed: return .terminated(session)
        case .idle, .loading, .ready, .playing, .paused, .buffering: return self
        }
    }

    /// A load opens the next session, live.
    func opening() -> SessionPhase { .live(id.next()) }
}

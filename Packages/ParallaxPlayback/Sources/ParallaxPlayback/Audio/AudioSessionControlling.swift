import Foundation

/// Abstracts `AVAudioSession` configuration.
///
/// The concrete implementation (`LiveAudioSession`) lives in the app target
/// and calls `AVAudioSession.sharedInstance().setCategory(.playback, ...)`.
/// This protocol keeps `ParallaxPlayback` free of iOS-only APIs.
public protocol AudioSessionControlling: Sendable {
    /// Configures and activates the playback session (`.playback` category) so audio
    /// keeps playing in the background and over the silent switch. Throws if the
    /// system refuses activation (e.g. an interruption already owns the session).
    func activate() async throws
    /// Deactivates the session on teardown so other apps can resume. Best-effort —
    /// never throws (a failed deactivation isn't actionable from the player).
    func deactivate() async
}

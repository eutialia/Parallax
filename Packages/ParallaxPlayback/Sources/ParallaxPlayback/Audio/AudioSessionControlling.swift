import Foundation

/// Abstracts `AVAudioSession` configuration and route-change notifications.
///
/// The concrete implementation (`LiveAudioSession`) lives in the app target
/// and calls `AVAudioSession.sharedInstance().setCategory(.playback, ...)`.
/// This protocol keeps `ParallaxPlayback` free of iOS-only APIs.
///
/// `routeChanges` is an `AsyncStream<Void>` property (not a method) so
/// app-wiring code can for-await over it in a `Task` without holding a
/// reference to the concrete type. Each emission signals that the audio route
/// changed and that `DeviceProfileBuilder.invalidate()` should be called; the
/// Void payload carries no route detail (the new profile is probed fresh on
/// the next `build()` call).
public protocol AudioSessionControlling: Sendable {
    /// Configures and activates the playback session (`.playback` category) so audio
    /// keeps playing in the background and over the silent switch. Throws if the
    /// system refuses activation (e.g. an interruption already owns the session).
    func activate() async throws
    /// Deactivates the session on teardown so other apps can resume. Best-effort —
    /// never throws (a failed deactivation isn't actionable from the player).
    func deactivate() async
    /// Fires once per audio-route change (headphones in/out, AirPlay handoff). Each
    /// emission signals the cached `DeviceProfile` is stale and must be rebuilt; see
    /// the type doc for why the payload is `Void`.
    var routeChanges: AsyncStream<Void> { get }
}

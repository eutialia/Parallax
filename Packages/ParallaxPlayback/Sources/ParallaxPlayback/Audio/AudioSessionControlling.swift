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
    func activate() async throws
    func deactivate() async
    var routeChanges: AsyncStream<Void> { get }
}

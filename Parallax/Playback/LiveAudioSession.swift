import AVFoundation
import os
import ParallaxCore
import ParallaxPlayback

/// iOS-only `AudioSessionControlling`. Configures `AVAudioSession` for
/// long-form video with AirPlay and bridges route-change notifications into a
/// `nonisolated` AsyncStream<Void> consumed by the app's launch-time invalidate
/// pipe. Per the spec, in-flight playback is NOT interrupted on a route change
/// — each emission only signals "rebuild the profile on the next resolve".
///
/// `nonisolated` + `@concurrent`: `setActive(true)` is a blocking IPC into the
/// media server — it must stay off the main thread. Dispatch through the
/// package's `any AudioSessionControlling` already lands off-main today, but
/// only because the package compiles without NonisolatedNonsendingByDefault
/// (its async requirements keep global-executor semantics) — a direct call on
/// the concrete type, or the package adopting approachable concurrency, would
/// silently pull this IPC onto the caller's (main) actor. `@concurrent` pins
/// the guarantee instead of inheriting it by accident.
nonisolated final class LiveAudioSession: AudioSessionControlling, @unchecked Sendable {
    let routeChanges: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var observer: NSObjectProtocol?

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.routeChanges = stream
        self.continuation = continuation
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [continuation] _ in
            continuation.yield(())
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        continuation.finish()
    }

    @concurrent func activate() async throws {
        let session = AVAudioSession.sharedInstance()
        // `.allowAirPlay` is only valid with `.playAndRecord`; passing it with
        // `.playback` makes setCategory throw (NSOSStatusErrorDomain -50), which
        // aborted every on-device playback. `.playback` already routes video to
        // AirPlay/external displays via the AVPlayer path, so the option is both
        // illegal and unnecessary here.
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
    }

    @concurrent func deactivate() async {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            Log.playback.error("AVAudioSession deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

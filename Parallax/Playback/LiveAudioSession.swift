import AVFoundation
import os
import ParallaxCore
import ParallaxPlayback

/// iOS-only `AudioSessionControlling`. Configures `AVAudioSession` for
/// long-form video with AirPlay and bridges route-change notifications into a
/// `nonisolated` AsyncStream<Void> consumed by the app's launch-time invalidate
/// pipe. Per the spec, in-flight playback is NOT interrupted on a route change
/// — each emission only signals "rebuild the profile on the next resolve".
final class LiveAudioSession: AudioSessionControlling, @unchecked Sendable {
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

    func activate() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
        try session.setActive(true)
    }

    func deactivate() async {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            Log.playback.error("AVAudioSession deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

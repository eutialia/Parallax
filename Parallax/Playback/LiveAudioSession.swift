import AVFoundation
import os
import ParallaxCore
import ParallaxPlayback

/// iOS-only `AudioSessionControlling`. Configures `AVAudioSession` for
/// long-form video with AirPlay.
///
/// `nonisolated` + `@concurrent`: `setActive(true)` is a blocking IPC into the
/// media server — it must stay off the main thread. Dispatch through the
/// package's `any AudioSessionControlling` already lands off-main today, but
/// only because the package compiles without NonisolatedNonsendingByDefault
/// (its async requirements keep global-executor semantics) — a direct call on
/// the concrete type, or the package adopting approachable concurrency, would
/// silently pull this IPC onto the caller's (main) actor. `@concurrent` pins
/// the guarantee instead of inheriting it by accident.
nonisolated final class LiveAudioSession: AudioSessionControlling {
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

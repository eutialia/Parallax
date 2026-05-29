import SwiftUI
import AVKit
import ParallaxPlayback

/// Hosts the engine's AVPlayer in a system AVPlayerViewController, which gives
/// PiP, AirPlay, the audio/subtitle picker, scrubbing, and Now Playing for
/// free. The engine is downcast to AVPlayerHosting; the cast can't fail in
/// Phase 4 (only AVKitEngine ships) but if it ever did we present an empty
/// controller and leave the VM to surface .unsupportedFormat.
struct AVPlayerViewControllerHost: UIViewControllerRepresentable {
    let engine: any PlaybackEngine

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        if let hosting = engine as? AVPlayerHosting {
            controller.player = hosting.avPlayer
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if let hosting = engine as? AVPlayerHosting, controller.player !== hosting.avPlayer {
            controller.player = hosting.avPlayer
        }
    }
}

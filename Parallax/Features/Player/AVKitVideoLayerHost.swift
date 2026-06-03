import SwiftUI
import UIKit
import AVKit
import ParallaxPlayback

/// Hosts the AVPlayer's video via a layer-backed AVPlayerLayer view and owns an
/// AVPictureInPictureController so PiP works when the engine supports it.
/// `onPiPReady` lets PlayerView/5e.4 push start/stop PiP actions back to the VM.
/// App target (UIKit/AVKit allowed here).
struct AVKitVideoLayerHost: UIViewRepresentable {
    let engine: any PlaybackEngine
    /// Aspect-fill (crop to fill) vs fit. Driven by the player's expand chip.
    var fillMode: Bool = false
    var onPiPReady: (@MainActor (@escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        if let hosting = engine as? AVPlayerHosting {
            view.playerLayer.player = hosting.avPlayer
        }
        view.playerLayer.videoGravity = fillMode ? .resizeAspectFill : .resizeAspect
        context.coordinator.attach(to: view)
        if let onPiPReady {
            let coordinator = context.coordinator
            onPiPReady({ coordinator.startPiP() }, { coordinator.stopPiP() })
        }
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if let hosting = engine as? AVPlayerHosting,
           uiView.playerLayer.player !== hosting.avPlayer {
            uiView.playerLayer.player = hosting.avPlayer
        }
        let gravity: AVLayerVideoGravity = fillMode ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A UIView whose backing layer IS an AVPlayerLayer (auto-sizes; no frame sync).
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    @MainActor
    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private var pip: AVPictureInPictureController?

        func attach(to view: PlayerLayerView) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
            guard let controller = AVPictureInPictureController(playerLayer: view.playerLayer) else { return }
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pip = controller
        }

        func startPiP() { pip?.startPictureInPicture() }
        func stopPiP()  { pip?.stopPictureInPicture() }
    }
}

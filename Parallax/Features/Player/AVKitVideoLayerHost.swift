import SwiftUI
import UIKit
import AVKit
import ParallaxPlayback

/// Hosts an `AVPlayerLayer`-backed `UIView` for the unified player surface.
/// Wires an `AVPictureInPictureController` for PiP.
///
/// Lives in the app target because `AVPlayerLayer`, `AVPictureInPictureController`,
/// and `UIView` are UIKit/AVKit types banned from `Packages/`.
struct AVKitVideoLayerHost: UIViewRepresentable {
    let engine: any PlaybackEngine

    // MARK: - Coordinator

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private(set) var pipController: AVPictureInPictureController?

        func setup(playerLayer: AVPlayerLayer) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
            guard let pip = AVPictureInPictureController(playerLayer: playerLayer) else { return }
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pip.delegate = self
            pipController = pip
        }

        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {}

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {}
    }

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if let hosting = engine as? AVPlayerHosting {
            let layer = AVPlayerLayer(player: hosting.avPlayer)
            layer.videoGravity = .resizeAspect
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            context.coordinator.setup(playerLayer: layer)
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Sync the player layer frame to the current view bounds. Wrap in a
        // CATransaction with actions disabled so the layer frame change does NOT
        // animate (the default implicit CALayer animation would visibly slide/
        // resize the video on rotation or layout changes).
        if let playerLayer = uiView.layer.sublayers?.first(where: { $0 is AVPlayerLayer }) as? AVPlayerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = uiView.bounds
            CATransaction.commit()
        }
    }
}

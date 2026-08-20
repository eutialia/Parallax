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
    var onPiPReady: (@MainActor (@escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?
    /// Pushes freeze/unfreeze actions back to the VM (same shape as `onPiPReady`):
    /// freeze snapshots the current video frame OVER the layer, unfreeze crossfades it
    /// away. The VM brackets engine-reusing reloads with them — `AVPlayerLayer` makes
    /// no hold-the-last-frame guarantee across `replaceCurrentItem` (device-observed:
    /// a subtitle-toggle reload held the frame, a scrub re-anchor flushed to black —
    /// same code path, AVFoundation race), so the snapshot makes the hold deterministic.
    var onFreezeReady: (@MainActor (@escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        if let hosting = engine as? AVPlayerHosting {
            view.playerLayer.player = hosting.avPlayer
        }
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.attach(to: view)
        if let onPiPReady {
            let coordinator = context.coordinator
            onPiPReady({ coordinator.startPiP() }, { coordinator.stopPiP() })
        }
        if let onFreezeReady {
            onFreezeReady({ [weak view] in view?.freezeFrame() }, { [weak view] in view?.unfreezeFrame() })
        }
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if let hosting = engine as? AVPlayerHosting,
           uiView.playerLayer.player !== hosting.avPlayer {
            uiView.playerLayer.player = hosting.avPlayer
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A UIView whose backing layer IS an AVPlayerLayer (auto-sizes; no frame sync).
    /// Freeze/unfreeze come from `FreezableVideoView`, shared with the VLC host, which
    /// needs the same hold when its exit cut stops the player.
    final class PlayerLayerView: FreezableVideoView {
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
            #if !os(tvOS)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            #endif
            pip = controller
        }

        func startPiP() { pip?.startPictureInPicture() }
        func stopPiP()  { pip?.stopPictureInPicture() }
    }
}

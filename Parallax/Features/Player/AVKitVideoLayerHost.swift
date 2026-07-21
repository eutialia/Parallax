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
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        private var frozenFrame: UIView?
        private var fadingFrame: UIView?

        /// Pin a render-server snapshot of the current frame over the player layer.
        /// `afterScreenUpdates: false` grabs what's on screen NOW, before the reload
        /// flushes it — and captures AVPlayer content for non-DRM streams (Jellyfin
        /// transcodes aren't FairPlay). Idempotent: a reload chain (drain loop) must
        /// keep the FIRST frame, not re-snapshot a possibly-black mid-swap surface.
        func freezeFrame() {
            guard frozenFrame == nil else { return }
            // A rapid scrub chain can re-freeze inside the previous snapshot's fade —
            // drop the fading one first so full-screen captures never stack.
            fadingFrame?.removeFromSuperview()
            fadingFrame = nil
            guard let snapshot = snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(snapshot)
            frozenFrame = snapshot
        }

        /// Crossfade the snapshot away — called once the swapped-in session renders
        /// (its first live beat), so real frames replace the frozen one seamlessly.
        func unfreezeFrame() {
            guard let snapshot = frozenFrame else { return }
            frozenFrame = nil
            fadingFrame = snapshot
            UIView.animate(withDuration: 0.25, animations: { snapshot.alpha = 0 }) { [weak self] _ in
                snapshot.removeFromSuperview()
                if self?.fadingFrame === snapshot { self?.fadingFrame = nil }
            }
        }
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

import UIKit

/// A video surface that can pin a still of its current content over itself.
///
/// The frame on screen has to survive the player's own decode surface going away. AVKit's
/// `replaceCurrentItem` makes no hold-the-last-frame guarantee across a track-switch reload
/// (device-observed: a subtitle toggle held the frame, a scrub re-anchor flushed to black on
/// the same code path, AVFoundation race).
///
/// A render-server snapshot is what makes the hold deterministic; the video layer's own
/// contents are not something AVFoundation promises to leave behind.
class FreezableVideoView: UIView {

    private var frozenFrame: UIView?
    private var fadingFrame: UIView?

    /// Pin a render-server snapshot of the current frame over the surface.
    /// `afterScreenUpdates: false` grabs what's on screen NOW, before the reload (or the
    /// exit stop) flushes it, and captures AVPlayer content for non-DRM streams (Jellyfin
    /// transcodes aren't FairPlay). Idempotent: a reload chain (drain loop) must keep the
    /// FIRST frame, not re-snapshot a possibly-black mid-swap surface.
    func freezeFrame() {
        guard frozenFrame == nil else { return }
        // A rapid scrub chain can re-freeze inside the previous snapshot's fade, so
        // drop the fading one first and full-screen captures never stack.
        fadingFrame?.removeFromSuperview()
        fadingFrame = nil
        guard let snapshot = snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(snapshot)
        frozenFrame = snapshot
    }

    /// Crossfade the snapshot away, called once the swapped-in session renders
    /// (its first live beat), so real frames replace the frozen one seamlessly.
    /// Never called on the exit path: that freeze is meant to outlive the session.
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

import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif
import ParallaxPlayback

/// Hosts VLC's render surface inside a SwiftUI view hierarchy.
///
/// MobileVLCKit 3.x has no Picture-in-Picture API — the drawable here is the plain
/// `UIView` VLC renders into (`player.drawable = view`), with no PiP bridge to keep
/// alive. `VLCKitEngine` reports `supportsPiP: false`, which is what hides the PiP
/// button on this engine.
struct VLCVideoHost: UIViewRepresentable {
    let engine: any PlaybackEngine
    /// Pushes freeze/unfreeze actions back to the VM (same shape as `AVKitVideoLayerHost`'s).
    /// The exit path needs it here: VLC's terminal audio cut is `player.stop()`
    /// (`VLCKitEngine.endAudio()`, since mute alone can't reach queued samples), which closes
    /// the vout, so without a pinned still the card would slide out on black instead of the
    /// last frame.
    var onFreezeReady: (@MainActor (@escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?

    // MARK: - DrawableView

    /// The UIView VLC renders into. Handed straight to `player.drawable`; VLC adds and
    /// lays out its own render subview inside it, which a `FreezableVideoView` snapshot
    /// captures along with everything else on the surface.
    final class DrawableView: FreezableVideoView {}

    // MARK: - Coordinator

    /// Owns the attach/detach of the render surface. Plain `NSObject` holding a
    /// `@MainActor` API only: nothing here is called from VLC's own threads, so no
    /// `nonisolated(unsafe)` storage is needed.
    @MainActor
    final class Coordinator {

        /// The captured `VLCMediaPlayer`. `VLCKitEngine` owns its lifecycle and exposes it
        /// as a drawable handle — this type sets `drawable` and nothing else.
        private var player: VLCMediaPlayer?

        /// Point VLC's video output at `view` unless this player already owns it; a
        /// no-op otherwise, so ordinary view updates don't churn the drawable. Same
        /// contract `AVKitVideoLayerHost.updateUIView` keeps for `playerLayer.player`.
        ///
        /// Identity of the PLAYER, not of the engine: the coordinator retains `player`,
        /// so the comparison can never be fooled by a freed address a new allocation
        /// reused — and `VLCKitEngine` mints exactly one player per engine (`mediaPlayer`
        /// is a stored `let`), so a rebuilt engine always brings a different one.
        ///
        /// The engine reaching here can be an AVKit one for a frame — SwiftUI can update
        /// this host with the replacement already installed, mid-reroute — and that must
        /// still release the surface, so the detach happens before the cast is required.
        func attachIfNeeded(to view: UIView, engine: any PlaybackEngine) {
            let hosting = engine as? any VLCPlayerHosting
            guard hosting?.vlcPlayer !== player else { return }
            detach()
            guard let hosting else { return }
            player = hosting.vlcPlayer
            hosting.vlcPlayer.drawable = view
        }

        /// Drop the current attachment — when SwiftUI removes the host
        /// (`dismantleUIView`), so VLC stops drawing into a view that is about to go away,
        /// and ahead of a re-attach so the outgoing player releases the surface first.
        /// Belt-and-suspenders to the engine's own `drawable = nil` in `teardown()`.
        ///
        /// Safe against a player the engine already tore down: `VLCKitEngine.teardown()`
        /// writes this exact field (`player.drawable = nil`) and never releases the
        /// player — `mediaPlayer` is a stored `let` that outlives teardown — so this is a
        /// redundant write to a live object, not a use-after-free.
        func detach() {
            player?.drawable = nil
            player = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> DrawableView {
        let view = DrawableView()
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        context.coordinator.attachIfNeeded(to: view, engine: engine)
        if let onFreezeReady {
            onFreezeReady({ [weak view] in view?.freezeFrame() }, { [weak view] in view?.unfreezeFrame() })
        }
        return view
    }

    /// VLC manages its own render subview layout, so there is no frame to sync — but the
    /// engine underneath can be rebuilt while `engine.id` stays `.vlcKit`, which keeps this
    /// view mounted, so the drawable has to be re-asked for on every update.
    func updateUIView(_ uiView: DrawableView, context: Context) {
        context.coordinator.attachIfNeeded(to: uiView, engine: engine)
    }

    static func dismantleUIView(_ uiView: DrawableView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

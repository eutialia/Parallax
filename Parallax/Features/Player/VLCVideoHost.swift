import SwiftUI
import UIKit
import MobileVLCKit
import ParallaxPlayback

/// Hosts VLC's render surface inside a SwiftUI view hierarchy.
///
/// MobileVLCKit 3.x has no Picture-in-Picture API — `VLCDrawable`,
/// `VLCPictureInPictureDrawable` and `VLCPictureInPictureMediaControlling` are all 4.x
/// protocols — so the drawable here is the plain `UIView` VLC renders into
/// (`player.drawable = view`), with no PiP bridge to keep alive. `VLCKitEngine` reports
/// `supportsPiP: false`, which is what hides the PiP button on this engine.
struct VLCVideoHost: UIViewRepresentable {
    let engine: any PlaybackEngine

    // MARK: - DrawableView

    /// The UIView VLC renders into. Handed straight to `player.drawable`; VLC adds and
    /// lays out its own render subview inside it.
    final class DrawableView: UIView {}

    // MARK: - Coordinator

    /// Owns the attach/detach of the render surface. Plain `NSObject` holding a
    /// `@MainActor` API only: unlike the 4.x PiP bridge, nothing here is called from
    /// VLC's own threads, so no `nonisolated(unsafe)` storage is needed.
    @MainActor
    final class Coordinator {

        /// The captured `VLCMediaPlayer`. `VLCKitEngine` owns its lifecycle and exposes it
        /// as a drawable handle — this type sets `drawable` and nothing else.
        private var player: VLCMediaPlayer?

        /// Point VLC's video output at `view`. Called from `makeUIView`.
        func attach(to view: UIView, engine: any PlaybackEngine) {
            guard let hosting = engine as? any VLCPlayerHosting else { return }
            let vlcPlayer = hosting.vlcPlayer
            player = vlcPlayer
            vlcPlayer.drawable = view
        }

        /// Detach the render surface when SwiftUI removes the host (`dismantleUIView`), so
        /// VLC stops drawing into a view that is about to go away. Belt-and-suspenders to
        /// the engine's own `drawable = nil` in `teardown()`.
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
        context.coordinator.attach(to: view, engine: engine)
        return view
    }

    func updateUIView(_ uiView: DrawableView, context: Context) {
        // VLC manages its own render subview layout — no frame sync needed.
    }

    static func dismantleUIView(_ uiView: DrawableView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

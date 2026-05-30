import SwiftUI
import UIKit
import VLCKitSPM
import ParallaxPlayback

/// Hosts VLC's render surface inside a SwiftUI view hierarchy.
///
/// Sets `vlcPlayer.drawable` to a plain `UIView` subclass so VLC can inject
/// its own render subview into it. VLC manages all subview layout internally;
/// no frame synchronisation is needed from this side.
///
/// `VLCPictureInPictureDrawable` conformance (which enables VLC's internal PiP
/// controller) is wired in Task 5e. This task establishes the drawable binding
/// so video renders; PiP is inert until then.
///
/// - Note: `vlcPlayer.drawable` is typed as `id` (any NSObject) in 4.x — a
///   plain `UIView` subclass is accepted without needing to explicitly conform
///   to `VLCDrawable`. The `VLCDrawable` protocol merely documents the two
///   selectors VLC invokes (`addSubview:` and `bounds`), both of which `UIView`
///   already provides.
struct VLCVideoHost: UIViewRepresentable {
    let engine: any PlaybackEngine

    // MARK: - DrawableView

    /// The UIView into which VLC renders. `UIView` satisfies VLC's internal
    /// drawable requirements (`addSubview:` / `bounds`) without needing an
    /// explicit `VLCDrawable` protocol declaration.
    final class DrawableView: UIView {}

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        weak var engine: (any PlaybackEngine)?
        init(engine: any PlaybackEngine) { self.engine = engine }
    }

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> DrawableView {
        let view = DrawableView()
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Set drawable before play() so VLC attaches its render subview.
        if let hosting = engine as? any VLCPlayerHosting {
            hosting.vlcPlayer.drawable = view
        }
        return view
    }

    func updateUIView(_ uiView: DrawableView, context: Context) {
        // VLC manages its own render subview layout — no frame sync needed.
    }
}

// TODO(5e): conform Coordinator to VLCPictureInPictureMediaControlling for PiP.
// Deferred because VLCPictureInPictureMediaControlling is an @objc protocol
// whose requirements surface in Swift as methods (not computed properties), and
// the @MainActor Coordinator would require nonisolated/unsafe bridging to satisfy
// the synchronous ObjC method dispatch. That friction belongs to 5e where PiP
// is actually wired end-to-end.

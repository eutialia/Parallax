import SwiftUI
import UIKit
import VLCKitSPM
import ParallaxPlayback

/// Hosts VLC's render surface inside a SwiftUI view hierarchy and bridges VLC's
/// 4.x Picture-in-Picture protocols.
///
/// The `Coordinator` is set as `vlcPlayer.drawable`. By conforming to
/// `VLCDrawable` it tells VLC where to inject its render subview (`addSubview:` /
/// `bounds`, forwarded to `hostView`); by conforming to
/// `VLCPictureInPictureDrawable` + `VLCPictureInPictureMediaControlling` it
/// enables VLC's internal PiP controller and answers the playback queries PiP
/// makes (length / time / seekability / play / pause / seek).
///
/// ## Concurrency
/// VLC invokes the drawable + PiP protocol selectors from its **own thread**,
/// not the main actor. A `@MainActor` Coordinator therefore cannot satisfy these
/// `@objc` requirements (they'd be actor-isolated and unreachable from VLC's
/// runtime). The Coordinator is consequently a plain `NSObject` and every
/// protocol member is `nonisolated`. The state those members read
/// (`player`, `hostView`, `windowControl`) lives in `nonisolated(unsafe)`
/// storage — see each field for its thread-confinement invariant. This is the
/// same tradeoff `VLCKitEngine` already makes for its `nonisolated(unsafe)`
/// player handle: the calls here are read-only queries or VLC-driven control
/// hops, and VLC serialises its own drawable callbacks.
struct VLCVideoHost: UIViewRepresentable {
    let engine: any PlaybackEngine
    /// Pushes PiP start/stop actions up to the VM once VLC's PiP window is ready.
    var onPiPReady: (@MainActor (@escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?

    // MARK: - DrawableView

    /// The UIView VLC renders into. VLC injects its own render subview via the
    /// Coordinator's `addSubview(_:)`, which forwards to this view.
    final class DrawableView: UIView {}

    // MARK: - Coordinator

    /// Bridges VLC's drawable + PiP protocols. NOT `@MainActor`: VLC calls these
    /// selectors off the main thread, so the conformance must be `nonisolated`.
    final class Coordinator: NSObject {

        /// The captured `VLCMediaPlayer`. VLC's PiP controller reads/controls it
        /// off the main thread; `VLCKitEngine` exposes it as a `nonisolated`
        /// drawable handle and owns its lifecycle. These PiP calls are read-only
        /// queries (time/length/seekable/playing) and VLC-driven control hops
        /// (play/pause/seek) that VLC already serialises — same confinement
        /// tradeoff as the engine's own player handle.
        nonisolated(unsafe) private var player: VLCMediaPlayer?

        /// The owning engine, captured in `attach`. PiP transport (`play()`/`pause()`)
        /// routes through it instead of the raw `player`, so a pause/play from VLC's PiP
        /// overlay emits the same `PlaybackState` beats the main UI and progress reporting
        /// consume (the raw player emits none — the engine's delegate `.paused`/`.playing`
        /// cases are ignored). `PlaybackEngine` is `Sendable`; same off-thread confinement
        /// as `player`.
        nonisolated(unsafe) private var engine: (any PlaybackEngine)?

        /// The view VLC injects its render subview into. Touched from `addSubview`
        /// / `bounds`, which VLC drives on its drawable callback (in practice on
        /// the main thread for view mutation); held weakly so it follows the
        /// SwiftUI-owned view's lifetime.
        nonisolated(unsafe) private weak var hostView: UIView?

        /// VLC's PiP activation controller, handed to us via `pictureInPictureReady`.
        /// Assigned on the main actor (the PiP-ready callback hops there) and nil'd by the
        /// `@MainActor` `detach()`, so the off-thread callback can't race teardown's nil-write;
        /// the invalidate timer (created in the `@MainActor` `attach`) resumes on the main
        /// actor to read it too.
        nonisolated(unsafe) private var windowControl: (any VLCPictureInPictureWindowControlling)?

        /// Set by `detach()` so the off-thread `pictureInPictureReady` callback can't
        /// resurrect `windowControl` (or fire `onPiPReady`) after the host is torn down.
        nonisolated(unsafe) private var isDetached = false

        /// Periodically nudges VLC's PiP overlay to refresh its playback state.
        private var pipInvalidateTask: Task<Void, Never>?

        /// Last known media duration (ms). VLCKit 4.x's `player.media` getter retains
        /// the libvlc media WITHOUT a null check, so reading it while no media is set
        /// (before load / during teardown) aborts in `libvlc_media_retain`. `mediaLength()`
        /// only refreshes this from the getter when `hasVideoOut` proves a media is open,
        /// and returns the cached value otherwise.
        nonisolated(unsafe) private var cachedLengthMs: Int64 = 0

        deinit { pipInvalidateTask?.cancel() }

        /// Tear the drawable + PiP bridge down on the main thread when SwiftUI
        /// removes the host (`dismantleUIView`). Stops the invalidate timer and drops
        /// the player/window references so a late, off-thread PiP query short-circuits
        /// to its nil-coalesced default instead of racing the engine freeing the media.
        /// Belt-and-suspenders to the engine's own `drawable = nil` in `teardown()`.
        @MainActor
        func detach() {
            isDetached = true
            pipInvalidateTask?.cancel()
            pipInvalidateTask = nil
            player?.drawable = nil
            windowControl = nil
            player = nil
            engine = nil
            hostView = nil
        }

        /// Wire the drawable + PiP bridge. Runs on the main actor (called from
        /// `makeUIView`, which sets `onPiPReady` first). Order matters: VLC reads
        /// `pictureInPictureReady()` / `mediaController()` off `self` the moment it
        /// binds the drawable, so `self` must be fully configured before
        /// `drawable = self`.
        @MainActor
        func attach(to view: UIView, engine: any PlaybackEngine) {
            hostView = view
            self.engine = engine
            guard let hosting = engine as? any VLCPlayerHosting else { return }
            let vlcPlayer = hosting.vlcPlayer
            player = vlcPlayer

            // Set drawable LAST: VLC reads pictureInPictureReady() / mediaController()
            // off self when it binds the drawable, so self must be fully configured first.
            vlcPlayer.drawable = self

            // Keep VLC's PiP overlay (play/pause, scrubber) in sync. The engine's
            // PlaybackState stream is a *unicast* AsyncStream already consumed by
            // PlayerViewModel — a second `for await` here would steal beats from the
            // view model (it swallowed the `.ready` track inventory, so the track
            // menus came up empty, and split the position beats). Nudge PiP on a
            // timer instead; it only does anything once PiP is active (windowControl
            // set), and `invalidatePlaybackState` just asks VLC to re-read the
            // mediaController, so a 1s cadence is plenty for the overlay.
            pipInvalidateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.windowControl?.invalidatePlaybackState()
                }
            }
        }

        /// Stored so `pictureInPictureReady` (invoked by VLC off-thread) can hop
        /// the start/stop actions back to the main actor for the VM. Set by
        /// `makeUIView` before `attach`, so VLC has it when it binds the drawable.
        ///
        /// Plain `var` (not `nonisolated(unsafe)`): the Coordinator is a
        /// non-Sendable, non-isolated class, so the compiler does not impose a
        /// Sendable check when this MainActor-captured closure is stored from
        /// `makeUIView` — unlike `nonisolated(unsafe)` storage, which would force
        /// the assigned value to be Sendable and reject the VM-capturing closure.
        var onPiPReady: (@MainActor (@escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> DrawableView {
        let view = DrawableView()
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Set the PiP callback before attach() binds the drawable, so VLC has it
        // when it reads pictureInPictureReady() while initialising its controller.
        context.coordinator.onPiPReady = onPiPReady
        context.coordinator.attach(to: view, engine: engine)
        return view
    }

    func updateUIView(_ uiView: DrawableView, context: Context) {
        // VLC manages its own render subview layout — no frame sync needed.
    }

    /// SwiftUI removed the representable: detach the PiP bridge synchronously on the
    /// main thread so its off-thread media queries stop before the engine's teardown
    /// frees the media.
    static func dismantleUIView(_ uiView: DrawableView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

// MARK: - VLCDrawable

extension VLCVideoHost.Coordinator: VLCDrawable {
    /// VLC injects its render view here; forward into the SwiftUI-hosted view.
    func addSubview(_ view: UIView) {
        hostView?.addSubview(view)
    }

    /// VLC reads this to size its render view to our host. Bridged from ObjC
    /// `-(CGRect)bounds` as a method, not a property.
    func bounds() -> CGRect {
        hostView?.bounds ?? .zero
    }
}

// MARK: - VLCPictureInPictureDrawable

extension VLCVideoHost.Coordinator: VLCPictureInPictureDrawable {
    /// The object answering PiP's playback queries — that's us.
    func mediaController() -> (any VLCPictureInPictureMediaControlling)? { self }

    /// VLC calls this block once its PiP controller is ready, handing us the
    /// activation window. We stash it and forward start/stop closures to the VM.
    /// The window arrives optional (bridged from ObjC `id`); ignore a nil window.
    func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)? {
        { [weak self] window in
            guard let self, let window else { return }
            // VLC may invoke this off its own thread; hop to the main actor before touching
            // any state. `window` (owned by VLC's serialised PiP controller) and `self` are
            // non-Sendable, so carry them across the Task boundary through `nonisolated(unsafe)`
            // locals — the same thread-confinement contract as the engine's player handle.
            // Assigning `windowControl` here (rather than off-thread) serialises it with
            // detach()'s nil-write, and the `isDetached` guard stops a late callback
            // resurrecting it — or firing `onPiPReady` — after the host is torn down.
            nonisolated(unsafe) let unsafeWindow = window
            Task { @MainActor in
                guard !self.isDetached else { return }
                self.windowControl = unsafeWindow
                self.onPiPReady?(
                    { unsafeWindow.startPictureInPicture() },
                    { unsafeWindow.stopPictureInPicture() }
                )
            }
        }
    }
}

// MARK: - VLCPictureInPictureMediaControlling

extension VLCVideoHost.Coordinator: VLCPictureInPictureMediaControlling {
    /// Media duration in milliseconds (PiP expects `int64_t`).
    ///
    /// PiP polls this off the main thread. VLCKit 4.x's `player.media` getter retains
    /// the libvlc media without a null check, so it must only be touched when a media is
    /// actually open — `hasVideoOut` is the safe gate (true ⇒ media set & rendering).
    /// Outside that window (before load, during/after teardown) we return the cached
    /// length instead of risking `libvlc_media_retain(NULL)`.
    func mediaLength() -> Int64 {
        if let player, player.hasVideoOut, let length = player.media?.length.intValue {
            cachedLengthMs = Int64(length)
        }
        return cachedLengthMs
    }

    /// Current playback time in milliseconds.
    func mediaTime() -> Int64 {
        Int64(player?.time.intValue ?? 0)
    }

    func isMediaSeekable() -> Bool { player?.isSeekable ?? false }

    func isMediaPlaying() -> Bool { player?.isPlaying ?? false }

    /// Route PiP transport through the engine (not the raw player) so a pause/play from
    /// VLC's PiP overlay emits the same `PlaybackState` beats the main UI and progress
    /// reporting consume; the engine still drives the same player underneath.
    func play() {
        if let engine { Task { await engine.play() } } else { player?.play() }
    }

    func pause() {
        if let engine { Task { await engine.pause() } } else { player?.pause() }
    }

    /// Seek by a millisecond offset, then signal completion. `VLCTime(int:)`
    /// takes `Int32`, so clamp the resulting absolute time.
    func seek(by offset: Int64, completion: @escaping () -> Void) {
        if let player {
            let current = Int64(player.time.intValue)
            player.time = VLCTime(int: Int32(clamping: current + offset))
        }
        completion()
    }
}

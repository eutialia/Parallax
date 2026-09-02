import Testing
import UIKit
import CoreMedia
import ParallaxPlayback
@testable import Parallax
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif

/// The drawable hand-off `VLCVideoHost.Coordinator` performs when the view model rebuilds
/// the engine underneath a mounted host. App-hosted rather than a package test: the
/// coordinator lives in the app target, and `VLCKitEngine`/`VLCMediaPlayer` are real objects
/// here — an idle, media-less player is exactly what the surface contract is about.
@Suite("VLCVideoHost drawable attachment", .serialized)
@MainActor
struct VLCVideoHostAttachTests {

    /// A VLC→VLC rebuild keeps the host view mounted, so the ONLY thing that re-points the
    /// picture is this call. The old player has to let the surface go before the new one
    /// takes it: two players holding one drawable is the stalled-picture bug.
    @Test("a rebuilt engine takes the surface and the outgoing player releases it")
    func rebuiltEngineTakesTheSurface() {
        let view = UIView()
        let coordinator = VLCVideoHost.Coordinator()
        let old = VLCKitEngine()
        let new = VLCKitEngine(libraryOptions: ["--freetype-color=16777215"])
        #expect(old.vlcPlayer !== new.vlcPlayer)

        coordinator.attachIfNeeded(to: view, engine: old)
        #expect(old.vlcPlayer.drawable as? UIView === view)

        coordinator.attachIfNeeded(to: view, engine: new)
        #expect(old.vlcPlayer.drawable == nil)
        #expect(new.vlcPlayer.drawable as? UIView === view)
    }

    /// Ordinary SwiftUI updates run this on every body pass. Re-pointing an unchanged player
    /// tears the vout down and rebuilds it, so the second call has to be a true no-op —
    /// judged on the player's identity, which the coordinator retains, and not on the
    /// engine's address, which a new allocation can reuse once the old one is freed.
    @Test("a repeat update with the same engine leaves the drawable exactly as it was")
    func repeatUpdateIsANoOp() {
        let view = UIView()
        let other = UIView()
        let coordinator = VLCVideoHost.Coordinator()
        let engine = VLCKitEngine()

        coordinator.attachIfNeeded(to: view, engine: engine)
        // A second call with a DIFFERENT view proves identity, not mere non-nil-ness: an
        // unconditional re-attach would move the drawable to `other`.
        coordinator.attachIfNeeded(to: other, engine: engine)
        #expect(engine.vlcPlayer.drawable as? UIView === view)
    }

    /// Mid-reroute (AVKit→VLC and back) SwiftUI can hand this host an engine that vends no
    /// VLC player at all for a frame. The cast fails, but the outgoing player is still
    /// holding a view that is on its way out — so the surface has to be released anyway.
    @Test("an engine that hosts no VLC player still releases the outgoing surface")
    func nonHostingEngineReleasesTheSurface() {
        let view = UIView()
        let coordinator = VLCVideoHost.Coordinator()
        let engine = VLCKitEngine()

        coordinator.attachIfNeeded(to: view, engine: engine)
        coordinator.attachIfNeeded(to: view, engine: NonHostingEngine())
        #expect(engine.vlcPlayer.drawable == nil)
    }

    /// `dismantleUIView`'s path, and the belt-and-suspenders half of the engine's own
    /// `teardown()`: VLC must not be left drawing into a view SwiftUI is removing.
    @Test("detach releases the surface")
    func detachReleasesTheSurface() {
        let view = UIView()
        let coordinator = VLCVideoHost.Coordinator()
        let engine = VLCKitEngine()

        coordinator.attachIfNeeded(to: view, engine: engine)
        coordinator.detach()
        #expect(engine.vlcPlayer.drawable == nil)
    }
}

/// The AVKit side of a reroute, reduced to what the host cast sees: a `PlaybackEngine` that
/// is not a `VLCPlayerHosting`.
private final class NonHostingEngine: PlaybackEngine {
    nonisolated let id = PlaybackEngineID.avKit
    nonisolated let capabilities = PlaybackEngineCapabilities(
        supportsPiP: true, supportsVideoAirPlay: true, supportsNowPlayingIntegration: true
    )
    nonisolated let state = AsyncStream<PlaybackBeat> { $0.finish() }

    func load(_ asset: PlayableAsset) async throws -> PlaybackSessionID { .none.next() }
    func play() async {}
    func pause() async {}
    func seek(to time: CMTime) async {}
    func setAudioTrack(_ track: AudioTrack) async {}
    func setSubtitleTrack(_ track: SubtitleTrack?) async {}
    func teardown() async {}
}

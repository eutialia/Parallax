import Foundation
import CoreMedia
import Testing
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

/// The reactive AVKit→VLC fallback: some MP4-family files pass every pre-flight probe
/// but fail at DECODE time (`AVKitEngine`'s `AVPlayerItem.status` flips to `.failed`,
/// mid-load or mid-playback — see `AVKitEngine.handleStatusChange`). `PlayerViewModel`
/// re-routes the SAME asset onto VLCKit and retries exactly once —
/// `ReactiveFallback.shouldReroute` owns the pure decision, covered exhaustively (every
/// `Container` case, every engine/already-rerouted combination) in
/// `ParallaxPlaybackTests/ReactiveFallbackTests.swift`. These tests prove the VM-level
/// WIRING instead: which engine gets rebuilt and what the retry asset carries.
///
/// `.serialized` for the same reason as the other `PlayerViewModel` suites: these write
/// the process-wide `MPNowPlayingInfoCenter` via the VM's `NowPlayingController`.
@Suite("PlayerViewModel reactive AVKit→VLC fallback", .serialized)
@MainActor
struct ReactivePlaybackFallbackTests {

    /// Hands back a DIFFERENT fake engine per requested id, so a reroute (which asks the
    /// factory for `.vlcKit` after an `.avKit` engine already exists) is observable as a
    /// real engine swap, not the same instance replaying calls.
    private func makeSwitchingVM(
        reporting: StubPlaybackReporting = StubPlaybackReporting(),
        resolve: @escaping PlayerViewModel.ResolveCall,
        avKitEngine: FakePlaybackEngine,
        vlcEngine: FakePlaybackEngine
    ) -> PlayerViewModel {
        makePlayerVM(
            reporting: reporting,
            resolve: resolve,
            engineFactory: { id, _ in
                switch id {
                case .avKit: return avKitEngine
                case .vlcKit: return vlcEngine
                }
            }
        )
    }

    @Test("an AVKit decode failure on an MP4 direct-play reroutes once to VLC, preserving position and url")
    func reroutesOnceToVLC() async throws {
        let reporting = StubPlaybackReporting()
        let avKitEngine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()   // mp4 / h264 / aac direct-play
        let vm = makeSwitchingVM(
            reporting: reporting, resolve: { _, _, _, _ in resolved },
            avKitEngine: avKitEngine, vlcEngine: vlcEngine
        )

        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.engine === avKitEngine)

        avKitEngine.push(.playing(42))
        try await avKitEngine.settle()

        avKitEngine.push(.failed(.assetNotPlayable))
        // NO settle() after a beat that triggers the reroute: processing `.failed` makes
        // the fallback cancel this very subscription, and settle's "processed" proof is
        // the consumer's NEXT pull — a pull the cancel legitimately prevents (racing it
        // hangs the barrier forever). Wait on the reroute's observable outcome instead.
        // The CI-scaled overload, not the MainActor yield-loop: the reroute hop runs on
        // its own unstructured `Task`, so MainActor-only progress isn't guaranteed here.
        await waitUntil("VLC retry never reached play") { vlcEngine.calls.contains("play") }

        // The reroute swapped engines: a VLC asset was built and loaded, carrying the
        // SAME url/hints/vlcOptions and a start time resuming from the position AVKit
        // had reached — not zero, not the original resume offset.
        #expect(vm.engine === vlcEngine)
        #expect(avKitEngine.calls.contains("teardown"))
        #expect(vlcEngine.loadedAssets.count == 1)
        let retryAsset = try #require(vlcEngine.loadedAssets.first)
        let originalAsset = try #require(avKitEngine.loadedAssets.first)
        #expect(retryAsset.url == originalAsset.url)
        #expect(retryAsset.hints == originalAsset.hints)
        #expect(retryAsset.vlcOptions == originalAsset.vlcOptions)
        let resumeSeconds = CMTimeGetSeconds(try #require(retryAsset.startTime))
        #expect(abs(resumeSeconds - 42) < 0.01)
        #expect(vlcEngine.calls.contains("play"))

        // The VLC leg completes normally.
        vlcEngine.push(.playing(42))
        try await vlcEngine.settle()
        #expect(vm.phase == .playing)
    }

    @Test("a second failure — on the VLC retry itself — surfaces the normal error scrim, no further reroute")
    func vlcRetryFailureIsTerminal() async throws {
        let reporting = StubPlaybackReporting()
        let avKitEngine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()
        let vm = makeSwitchingVM(
            reporting: reporting, resolve: { _, _, _, _ in resolved },
            avKitEngine: avKitEngine, vlcEngine: vlcEngine
        )

        await vm.start(item: PlayerFixtures.movieDetail())
        avKitEngine.push(.failed(.assetNotPlayable))
        // Same barrier caveat as `reroutesOnceToVLC`: the reroute cancels this
        // subscription, so settle() can hang — wait on the outcome (CI-scaled overload,
        // same reasoning as `reroutesOnceToVLC`).
        await waitUntil("VLC retry never reached play") { vlcEngine.calls.contains("play") }
        #expect(vm.engine === vlcEngine)

        // VLC fails too — the one-shot is spent, so this must NOT build a third engine.
        vlcEngine.push(.failed(.assetNotPlayable))
        try await vlcEngine.settle()

        guard case .failed = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        #expect(vm.engine === vlcEngine)   // no further reroute — still the VLC engine
    }

    @Test("a Jellyfin HLS transcode failure never reactively reroutes — server problem, not a file defect")
    func transcodeFailureNeverReroutes() async throws {
        let reporting = StubPlaybackReporting()
        let avKitEngine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        // method: .transcode → hints.container is always .hls, regardless of the source.
        let resolved = PlayerFixtures.resolvedMultiTrackTranscode()
        let vm = makeSwitchingVM(
            reporting: reporting, resolve: { _, _, _, _ in resolved },
            avKitEngine: avKitEngine, vlcEngine: vlcEngine
        )

        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.engine === avKitEngine)

        avKitEngine.push(.failed(.assetNotPlayable))
        try await avKitEngine.settle()

        guard case .failed = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        #expect(vlcEngine.loadedAssets.isEmpty)   // no reroute attempted
    }

    @Test("a network-stalled AVKit failure never reactively reroutes — a link problem, not a decode defect")
    func networkStalledNeverReroutes() async throws {
        let reporting = StubPlaybackReporting()
        let avKitEngine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let resolved = PlayerFixtures.resolved()   // mp4 / h264 / aac direct-play
        let vm = makeSwitchingVM(
            reporting: reporting, resolve: { _, _, _, _ in resolved },
            avKitEngine: avKitEngine, vlcEngine: vlcEngine
        )

        await vm.start(item: PlayerFixtures.movieDetail())
        #expect(vm.engine === avKitEngine)

        avKitEngine.push(.failed(.networkStalled))
        try await avKitEngine.settle()

        guard case .failed = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        #expect(vlcEngine.loadedAssets.isEmpty)   // no reroute attempted — rerouting would tear
                                                   // down a working engine over an honest stall
    }

    @Test("the VLC retry asset carries the original's vlcLibraryOptions")
    func retryPreservesVLCLibraryOptions() async throws {
        let reporting = StubPlaybackReporting()
        let avKitEngine = FakePlaybackEngine(id: .avKit, capabilities: .avKit)
        let vlcEngine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeSwitchingVM(
            reporting: reporting,
            resolve: { _, _, _, _ in
                Issue.record("SMB playback must not call the Jellyfin resolve")
                throw AppError.playback(.unsupportedFormat)
            },
            avKitEngine: avKitEngine, vlcEngine: vlcEngine
        )

        // An AVKit-bridge-eligible SMB item (mp4/h264/aac over http), carrying a
        // probe-proven timing-hazard library option — the exact shape
        // `SMBPlaybackResolver` builds for a `.decodeOrderTimestamps` file. The reroute
        // must carry it onto the VLC retry — `PlayableAsset.replacingStartTime` must not
        // silently drop it.
        let libraryOptions = ["--no-drop-late-frames", "--no-skip-frames"]
        let smbItem = SMBPlaybackItem(
            itemID: ItemID(rawValue: "smb-fallback-item"),
            url: URL(string: "http://127.0.0.1:9000/Example.mp4")!,
            title: "Example",
            vlcOptions: [],
            vlcLibraryOptions: libraryOptions,
            hints: PlaybackHints(
                scheme: "http", container: .mp4, videoCodec: .h264, audioCodec: .aac, subtitleFormats: []
            )
        )
        await vm.start(smbItem: smbItem)
        #expect(vm.engine === avKitEngine)

        avKitEngine.push(.failed(.assetNotPlayable))
        await waitUntil("VLC retry never reached play") { vlcEngine.calls.contains("play") }

        let retryAsset = try #require(vlcEngine.loadedAssets.first)
        #expect(retryAsset.vlcLibraryOptions == libraryOptions)
    }
}

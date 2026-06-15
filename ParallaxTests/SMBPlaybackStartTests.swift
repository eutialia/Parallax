import Foundation
import CoreMedia
import Testing
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

/// SMB direct-play entry: `PlayerViewModel.start(smbItem:)` builds a `PlayableAsset`
/// straight from a local SMB file — no Jellyfin resolve, no DeviceProfile, no
/// playSessionID, no progress reporting. The libVLC `smb://` path is the validated
/// primary (the spike passed), so the asset routes to VLCKit via `hints.scheme == "smb"`
/// and carries the credential options verbatim in `vlcOptions`.
///
/// `.serialized` for the same reason as the Jellyfin suite: these write the
/// process-wide `MPNowPlayingInfoCenter` via the VM's NowPlayingController.
@Suite("PlayerViewModel SMB start", .serialized)
@MainActor
struct SMBPlaybackStartTests {

    /// A VM with a resolve closure that MUST NOT run on the SMB path — calling it
    /// fails the test, proving `start(smbItem:)` never touches the Jellyfin resolve.
    private func makeVM(
        reporting: StubPlaybackReporting,
        engine: FakePlaybackEngine,
        audioSession: any AudioSessionControlling = NoopAudioSession()
    ) -> PlayerViewModel {
        let probe = FakeCapabilityProbe(hdr: .none, audioOutput: .stereo)
        let builder = DeviceProfileBuilder(probe: probe)
        return PlayerViewModel(
            deviceProfileBuilder: builder,
            playbackInfo: reporting,
            resolve: { _, _, _, _, _ in
                Issue.record("SMB playback must not call the Jellyfin resolve")
                throw AppError.playback(.unsupportedFormat)
            },
            engineFactory: { _ in engine },
            audioSession: audioSession
        )
    }

    private func smbItem(
        url: String = "smb://nas.local/Media/Movies/Example.mkv",
        title: String = "Example",
        vlcOptions: [String] = [":smb-user=alice", ":smb-pwd=secret", ":smb-domain=WORKGROUP"],
        subtitleURLs: [Int: URL] = [:]
    ) -> SMBPlaybackItem {
        SMBPlaybackItem(
            url: URL(string: url)!,
            title: title,
            vlcOptions: vlcOptions,
            subtitleURLs: subtitleURLs
        )
    }

    @Test("builds a VLC smb:// asset carrying the credential options, then loads + plays")
    func startBuildsSMBAssetAndPlays() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let creds = [":smb-user=alice", ":smb-pwd=secret", ":smb-domain=WORKGROUP"]
        await vm.start(smbItem: smbItem(vlcOptions: creds))

        // Exactly one asset loaded, routed at smb, carrying the credential options.
        #expect(engine.loadedAssets.count == 1)
        let asset = try #require(engine.loadedAssets.first)
        #expect(asset.hints.scheme == "smb")
        #expect(asset.url.absoluteString == "smb://nas.local/Media/Movies/Example.mkv")
        #expect(asset.vlcOptions == creds)
        #expect(asset.headers == nil)              // no Jellyfin auth headers on the SMB path
        #expect(engine.calls.contains("load"))
        #expect(engine.calls.contains("play"))

        // The session reaches .playing once the engine reports it — proving the beat
        // handler doesn't drop SMB beats just because `resolved == nil`.
        engine.push(.playing(
            position: CMTime(seconds: 5, preferredTimescale: 1),
            duration: CMTime(seconds: 6000, preferredTimescale: 1),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.phase == .playing)
        #expect(vm.isPlaying == true)
    }

    @Test("a .ready beat publishes the engine inventory verbatim — no server subs appended (resolved == nil)")
    func readyPublishesEngineInventoryWithoutServerSubs() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        await vm.start(smbItem: smbItem())

        // The branch the handle(_:) refactor most affects: with resolved == nil,
        // `.ready` must take the direct-play path (resolved?.method != .transcode is
        // true), publish the engine's own tracks, and append ZERO external subs
        // (resolved.map(externalSubtitleTracks) ?? [] → []).
        let audio = AudioTrack(id: .vlc("a1"), displayName: "English", languageCode: "en")
        let sub = SubtitleTrack(id: .vlc("s1"), displayName: "English", languageCode: "en", isForced: false)
        engine.push(.ready(
            duration: CMTime(seconds: 6000, preferredTimescale: 1),
            tracks: TrackInventory(audio: [audio], subtitles: [sub])
        ))
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.availableAudioTracks.map(\.id) == [.vlc("a1")])
        // Exactly the engine's one sub — no Jellyfin sidecar tracks appended on SMB.
        #expect(vm.availableSubtitleTracks.map(\.id) == [.vlc("s1")])
    }

    @Test("subtitleURLs is populated from the smbItem's pre-resolved sidecar map")
    func startPopulatesSubtitleURLMap() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let subURL = URL(string: "file:///tmp/Example.en.srt")!
        await vm.start(smbItem: smbItem(subtitleURLs: [0: subURL]))

        #expect(vm.debugSubtitleURLs == [0: subURL])
    }

    @Test("no Jellyfin reporting fires on the SMB path — resolved stays nil end to end")
    func smbPathNeverReports() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        await vm.start(smbItem: smbItem())

        // Drive a full play → progress → ended lifecycle.
        engine.push(.playing(
            position: CMTime(seconds: 10, preferredTimescale: 1),
            duration: CMTime(seconds: 6000, preferredTimescale: 1),
            buffered: nil
        ))
        engine.push(.playing(
            position: CMTime(seconds: 20, preferredTimescale: 1),
            duration: CMTime(seconds: 6000, preferredTimescale: 1),
            buffered: nil
        ))
        engine.push(.paused(
            position: CMTime(seconds: 20, preferredTimescale: 1),
            duration: CMTime(seconds: 6000, preferredTimescale: 1),
            buffered: nil
        ))
        engine.push(.ended)
        try await Task.sleep(for: .milliseconds(50))

        // resolved == nil is observable through the report contract: a Jellyfin
        // session would have fired start/progress/stopped beats; the SMB session
        // fires NONE (no resolved → no beat to build, no playSessionID to report).
        #expect(await reporting.events.isEmpty)
        #expect(await reporting.pings.isEmpty)
        #expect(await reporting.stoppedEncodings.isEmpty)
    }

    @Test("stop() tears the SMB session down cleanly: subtitleURLs cleared, no reporting")
    func stopTearsDownCleanly() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let subURL = URL(string: "file:///tmp/Example.en.srt")!
        await vm.start(smbItem: smbItem(subtitleURLs: [0: subURL]))
        engine.push(.playing(
            position: CMTime(seconds: 15, preferredTimescale: 1),
            duration: CMTime(seconds: 6000, preferredTimescale: 1),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.debugSubtitleURLs == [0: subURL])

        await vm.stop()

        #expect(engine.calls.contains("teardown"))
        #expect(vm.debugSubtitleURLs.isEmpty)
        // A session that never reported start must never report stop.
        #expect(await reporting.events.isEmpty)
        #expect(await reporting.stoppedEncodings.isEmpty)
    }

    @Test("NoOpPlaybackReporting swallows every call without recording")
    func noOpReportingIsInert() async {
        let noop = NoOpPlaybackReporting()
        let beat = ProgressBeat(
            positionTicks: 1,
            isPaused: false,
            method: .directPlay,
            itemID: "x",
            mediaSourceID: "y",
            playSessionID: "z"
        )
        // All five methods are inert no-ops — no crash, nothing to assert beyond
        // "they're callable and return". (The real SMB safety is resolved == nil
        // gating the beat handler; this is belt-and-suspenders for the VM init.)
        await noop.reportStart(beat)
        await noop.reportProgress(beat)
        await noop.reportStopped(beat)
        await noop.stopEncoding(playSessionID: "z")
        await noop.pingSession(playSessionID: "z")
    }
}

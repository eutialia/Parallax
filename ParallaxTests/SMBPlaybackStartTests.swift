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
        audioSession: any AudioSessionControlling = NoopAudioSession(),
        subtitleFetch: @escaping @Sendable (URL) async -> Data? = { _ in nil },
        smbResumeStore: SMBResumeStore = .shared
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
            audioSession: audioSession,
            subtitleFetch: subtitleFetch,
            smbResumeStore: smbResumeStore
        )
    }

    /// Isolated defaults per test — mirrors `SMBResumeStoreTests`' hygiene so these tests
    /// never touch `UserDefaults.standard`.
    private func makeResumeStore(suite: String) throws -> (store: SMBResumeStore, defaults: UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (SMBResumeStore(defaults: defaults), defaults)
    }

    private func smbItem(
        url: String = "smb://nas.local/Media/Movies/Example.mkv",
        title: String = "Example",
        itemID: ItemID = ItemID(rawValue: "smb-test-item"),
        vlcOptions: [String] = [":smb-user=alice", ":smb-pwd=secret", ":smb-domain=WORKGROUP"],
        subtitleURLs: [Int: URL] = [:],
        subtitleLabels: [Int: String] = [:],
        hasTrustworthyDuration: Bool = true
    ) -> SMBPlaybackItem {
        SMBPlaybackItem(
            itemID: itemID,
            url: URL(string: url)!,
            title: title,
            vlcOptions: vlcOptions,
            subtitleURLs: subtitleURLs,
            subtitleLabels: subtitleLabels,
            hasTrustworthyDuration: hasTrustworthyDuration
        )
    }

    @Test("start(smbItem:) surfaces both labeled sidecars in the subtitle menu with the resolver's labels")
    func startSurfacesLabeledSidecarsInMenu() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let en = URL(string: "smb://nas.local/Media/Movies/Example.en.srt")!
        let ja = URL(string: "smb://nas.local/Media/Movies/Example.ja.srt")!
        await vm.start(smbItem: smbItem(
            subtitleURLs: [0: en, 1: ja],
            subtitleLabels: [0: "en", 1: "ja"]
        ))

        // Both sidecars are selectable menu entries even before any engine .ready beat,
        // carrying the resolver's labels and client-render `.jellyfinStream` ids.
        let subs = vm.availableSubtitleTracks
        #expect(subs.count == 2)
        #expect(subs.contains { $0.id == .jellyfinStream(0) && $0.displayName == "en" && $0.isExternal })
        #expect(subs.contains { $0.id == .jellyfinStream(1) && $0.displayName == "ja" && $0.isExternal })
    }

    @Test("start(smbItem:) hides ASS/SSA sidecars from the menu — no client renderer yet")
    func startHidesUnrenderableSidecarFormats() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let srt = URL(string: "smb://nas.local/Media/Movies/x.srt")!
        let ass = URL(string: "smb://nas.local/Media/Movies/y.ass")!
        let vtt = URL(string: "smb://nas.local/Media/Movies/z.vtt")!
        await vm.start(smbItem: smbItem(
            subtitleURLs: [0: srt, 1: ass, 2: vtt],
            subtitleLabels: [0: "srt-label", 1: "ass-label", 2: "vtt-label"]
        ))

        // The resolver's filename matcher still surfaces the ASS sidecar (matched, just
        // unrenderable client-side) — the fix filters it out of the MENU, not the resolver.
        let subs = vm.availableSubtitleTracks
        #expect(subs.count == 2)
        #expect(subs.contains { $0.id == .jellyfinStream(0) && $0.displayName == "srt-label" })
        #expect(subs.contains { $0.id == .jellyfinStream(2) && $0.displayName == "vtt-label" })
        #expect(!subs.contains { $0.id == .jellyfinStream(1) })
    }

    @Test("selecting an SMB .srt sidecar fetches + parses via SRTParser into activeSubtitleCues")
    func selectingSRTSidecarParsesViaSRTParser() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)

        // A minimal single-cue SRT blob — comma timing WebVTTParser can't read, so a green
        // count proves the extension routed to SRTParser rather than WebVTTParser (→ 0 cues).
        let srt = "1\n00:00:01,000 --> 00:00:04,000\nHello world\n"
        let subURL = URL(string: "smb://nas.local/Media/Movies/Example.en.srt")!
        let vm = makeVM(reporting: reporting, engine: engine, subtitleFetch: { url in
            url == subURL ? Data(srt.utf8) : nil
        })

        await vm.start(smbItem: smbItem(subtitleURLs: [0: subURL], subtitleLabels: [0: "en"]))

        let track = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(0) })
        await vm.selectSubtitleTrack(track)
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.activeSubtitleCues.count == 1)
        #expect(vm.activeSubtitleCues.first?.text == "Hello world")
    }

    /// Counts resolve-closure invocations so a test can prove `retry()` replays it.
    private actor ResolveAttempts {
        private(set) var count = 0
        func bump() -> Int { count += 1; return count }
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
        let suite = "SMBPlaybackStartTests.stopTearsDownCleanly"
        let (store, defaults) = try makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)

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

    // MARK: - Local resume vs an untrusted (estimated) duration

    @Test("an untrusted duration never lets the 95%-complete rule clear a real resume position")
    func untrustedDurationSurvivesNearEndSave() async throws {
        let suite = "SMBPlaybackStartTests.untrustedDurationSurvivesNearEndSave"
        let (store, defaults) = try makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)
        let id = ItemID(rawValue: "smb-untrusted-duration")

        // An incomplete/still-downloading file: VLCKitEngine synthesizes a numeric duration
        // from its read-rate estimate, so `hasKnownDuration` reads true even though the
        // length isn't real. Position sits at 98.3% of that estimate — the shape that would
        // trip the store's 95%-complete clear if the duration were trusted.
        await vm.start(smbItem: smbItem(itemID: id, hasTrustworthyDuration: false))
        engine.push(.playing(
            position: CMTime(seconds: 5_900, preferredTimescale: 1),
            duration: CMTime(seconds: 6_000, preferredTimescale: 1),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        // stop()'s final save is unthrottled and inline-awaited — deterministic to assert
        // straight after, no throttle-window race.
        await vm.stop()

        let resumed = try #require(await store.resumeTime(for: id))
        #expect(abs(CMTimeGetSeconds(resumed) - 5_900) < 0.001)
    }

    @Test("a trusted duration DOES let the 95%-complete rule clear the resume position (counterpart)")
    func trustedDurationClearsNearEndSave() async throws {
        let suite = "SMBPlaybackStartTests.trustedDurationClearsNearEndSave"
        let (store, defaults) = try makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)
        let id = ItemID(rawValue: "smb-trusted-duration")

        // Identical position/duration shape, but a proven-complete file this time — the
        // 95%-complete rule is meant to fire here (a finished film restarts from the top).
        await vm.start(smbItem: smbItem(itemID: id, hasTrustworthyDuration: true))
        engine.push(.playing(
            position: CMTime(seconds: 5_900, preferredTimescale: 1),
            duration: CMTime(seconds: 6_000, preferredTimescale: 1),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))

        await vm.stop()

        #expect(await store.resumeTime(for: id) == nil)
    }

    @Test("a stale throttled save can't outrun .ended's terminal clear")
    func throttledSaveNeverOutrunsEndedClear() async throws {
        let suite = "SMBPlaybackStartTests.throttledSaveNeverOutrunsEndedClear"
        let (store, defaults) = try makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)
        let id = ItemID(rawValue: "smb-save-vs-clear")

        await vm.start(smbItem: smbItem(itemID: id))

        // The throttle window is wide open (first beat), so `.playing` spawns the untracked
        // save `.ended` must now await. Before the fix, the save Task's actor hop could lose
        // a race against `.ended`'s clear() — landing after it and resurrecting this position.
        engine.push(.playing(
            position: CMTime(seconds: 100, preferredTimescale: 1),
            duration: CMTime(seconds: 6_000, preferredTimescale: 1),
            buffered: nil
        ))
        engine.push(.ended)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await store.resumeTime(for: id) == nil)
    }

    // MARK: - start(resolvingSMB:) — resolve under the veil

    @Test("resolving start: the closure's item is loaded + played, no Jellyfin reporting")
    func resolvingStartLoadsResolvedItem() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let creds = [":smb-user=alice", ":smb-pwd=secret", ":smb-domain=WORKGROUP"]
        let resolved = smbItem(vlcOptions: creds)
        await vm.start(resolvingSMB: { resolved })

        // Same assertions as startBuildsSMBAssetAndPlays: the resolve closure's item
        // is the one the engine loaded + played, routed at smb with the creds verbatim.
        #expect(engine.loadedAssets.count == 1)
        let asset = try #require(engine.loadedAssets.first)
        #expect(asset.hints.scheme == "smb")
        #expect(asset.url.absoluteString == "smb://nas.local/Media/Movies/Example.mkv")
        #expect(asset.vlcOptions == creds)
        #expect(asset.headers == nil)
        #expect(engine.calls.contains("load"))
        #expect(engine.calls.contains("play"))

        engine.push(.playing(
            position: CMTime(seconds: 5, preferredTimescale: 1),
            duration: CMTime(seconds: 6000, preferredTimescale: 1),
            buffered: nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.phase == .playing)

        // No server in the loop: the resolve-then-delegate path reports nothing.
        #expect(await reporting.events.isEmpty)
        #expect(await reporting.pings.isEmpty)
        #expect(await reporting.stoppedEncodings.isEmpty)
    }

    @Test("resolving start: a resolve that throws an AppError lands on the failure scrim; the engine never loads")
    func resolvingStartSurfacesAppErrorOnFailureScrim() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let thrown = AppError.source(.notFound)
        await vm.start(resolvingSMB: { throw thrown })

        guard case .failed(let error) = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        #expect(error.diagnosticDescription == thrown.diagnosticDescription)
        // Resolution failed before any asset reached the engine.
        #expect(engine.loadedAssets.isEmpty)
        #expect(!engine.calls.contains("load"))
        #expect(await reporting.events.isEmpty)
    }

    @Test("retry() replays the SMB resolve closure — Try again is live on the SMB path")
    func retryReplaysSMBResolve() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let attempts = ResolveAttempts()
        let resolved = smbItem()
        let resolve: () async throws -> SMBPlaybackItem = {
            _ = await attempts.bump()
            return resolved
        }

        await vm.start(resolvingSMB: resolve)
        #expect(await attempts.count == 1)

        // retry() sets neither playingItem nor pendingItemID on the SMB path, so before the
        // fix it fell through to a no-op log and the closure was never re-run (dead "Try
        // again"). It must now replay the stored SMB resolve.
        await vm.retry()
        #expect(await attempts.count == 2)
        #expect(engine.calls.contains("load"))
    }

    /// Records how many times the bridge cleanup was invoked.
    private actor CleanupSpy {
        private(set) var count = 0
        func invoke() { count += 1 }
    }

    @Test("resolving start: an exit racing the resolve reaps the bridge cleanup (no orphan)")
    func resolvingStartExitRaceReapsBridge() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let spy = CleanupSpy()
        let base = smbItem()
        // A bridge-route item: cleanup holds a LIVE bridge the session must reap on exit.
        let resolvedItem = SMBPlaybackItem(
            itemID: base.itemID,
            url: base.url,
            title: base.title,
            vlcOptions: base.vlcOptions,
            cleanup: { await spy.invoke() }
        )

        // The resolve runs stop() to completion mid-flight (the onDisappear backstop landing
        // in the resolve window), THEN returns the item. Before the fix the cleanup was
        // stashed only inside start(smbItem:) — never reached past the exit fence — so the
        // bridge orphaned: stop() ran with smbCleanup still nil and never runs again.
        await vm.start(resolvingSMB: {
            await vm.stop()
            return resolvedItem
        })

        // The exit fence bailed before start(smbItem:), so the engine never loaded — but the
        // stashed cleanup was reaped exactly once by the CancellationError branch.
        #expect(!engine.calls.contains("load"))
        #expect(await spy.count == 1)
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

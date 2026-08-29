import Foundation
import CoreMedia
import Testing
import ParallaxCore
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxSubtitles
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
        // NOT `SMBResumeStore.shared`: that one reads and writes the real `UserDefaults.standard`
        // domain, so every test here that drives a `.playing` beat was writing live app state.
        smbResumeStore: SMBResumeStore? = nil,
        subtitleStyle: @escaping @MainActor () -> SubtitleStyle = { .standard },
        observeLibraryOptions: @escaping @MainActor @Sendable ([String]?) -> Void = { _ in }
    ) -> PlayerViewModel {
        return PlayerViewModel(
            deviceProfileBuilder: makeTestDeviceProfileBuilder(),
            playbackInfo: reporting,
            resolve: { _, _, _, _ in
                Issue.record("SMB playback must not call the Jellyfin resolve")
                throw AppError.playback(.unsupportedFormat)
            },
            engineFactory: { _, options in observeLibraryOptions(options); return engine },
            audioSession: audioSession,
            subtitleFetch: subtitleFetch,
            smbResumeStore: smbResumeStore ?? SMBTestFixtures.inertResumeStore(),
            subtitleStyle: subtitleStyle
        )
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
        // with the resolver's language labels translated to localized names (the
        // Jellyfin naming tier) and client-render `.jellyfinStream` ids. Expected
        // names are computed with the same current-locale call the production path
        // uses, so the assertion holds on a non-English test host.
        let subs = vm.availableSubtitleTracks
        #expect(subs.count == 2)
        let english = try #require(TrackDisplay.languageName("en"))
        let japanese = try #require(TrackDisplay.languageName("ja"))
        #expect(subs.contains { $0.id == .jellyfinStream(0) && $0.displayName == english && $0.languageCode == "en" && $0.isExternal })
        #expect(subs.contains { $0.id == .jellyfinStream(1) && $0.displayName == japanese && $0.languageCode == "ja" && $0.isExternal })
    }

    @Test("start(smbItem:) surfaces every renderable sidecar (ASS included) and hides formats the renderer can't ingest")
    func startFiltersSidecarFormatsByRenderability() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        let srt = URL(string: "smb://nas.local/Media/Movies/x.srt")!
        let ass = URL(string: "smb://nas.local/Media/Movies/y.ass")!
        let idx = URL(string: "smb://nas.local/Media/Movies/y.idx")!
        let vtt = URL(string: "smb://nas.local/Media/Movies/z.vtt")!
        await vm.start(smbItem: smbItem(
            subtitleURLs: [0: srt, 1: ass, 2: vtt, 3: idx],
            subtitleLabels: [0: "srt-label", 1: "ass-label", 2: "vtt-label", 3: "idx-label"]
        ))

        // ASS renders client-side (libass) so it's a real menu entry now; the VobSub
        // index file is image-based and stays out of the menu.
        let subs = vm.availableSubtitleTracks
        #expect(subs.count == 3)
        #expect(subs.contains { $0.id == .jellyfinStream(0) && $0.displayName == "srt-label" })
        #expect(subs.contains { $0.id == .jellyfinStream(1) && $0.displayName == "ass-label" })
        #expect(subs.contains { $0.id == .jellyfinStream(2) && $0.displayName == "vtt-label" })
        #expect(!subs.contains { $0.id == .jellyfinStream(3) })
    }

    @Test("selecting an SMB .srt sidecar fetches + loads the client renderer as SRT")
    func selectingSRTSidecarLoadsRenderer() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)

        // A minimal single-cue SRT blob with comma timing — the format tag proves the
        // extension routed the data down the renderer's SRT ingest, not the VTT one.
        let srt = "1\n00:00:01,000 --> 00:00:04,000\nHello world\n"
        let subURL = URL(string: "smb://nas.local/Media/Movies/Example.en.srt")!
        let vm = makeVM(reporting: reporting, engine: engine, subtitleFetch: { url in
            url == subURL ? Data(srt.utf8) : nil
        })

        await vm.start(smbItem: smbItem(subtitleURLs: [0: subURL], subtitleLabels: [0: "en"]))

        let track = try #require(vm.availableSubtitleTracks.first { $0.id == .jellyfinStream(0) })
        await vm.selectSubtitleTrack(track)
        await vm.debugAwaitSubtitleFetch()

        #expect(vm.sidecarSubtitleInfo == SidecarSubtitleInfo(format: .srt, byteCount: srt.utf8.count))
        #expect(vm.subtitleRenderer != nil)
    }

    /// SMB has no subtitle-extraction endpoint, so a track muxed into the container can
    /// only be drawn by the engine. That is the one direct-play case Jellyfin's
    /// sidecar takeover does NOT cover, and the asset must leave the engine free to
    /// render it (`engineSubtitlesDisabled == false`).
    @Test("SMB: an EMBEDDED pick still goes to the engine, and the asset keeps engine subtitles on")
    func smbEmbeddedSubtitleStaysWithTheEngine() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: reporting, engine: engine)

        await vm.start(smbItem: smbItem())
        let asset = try #require(engine.loadedAssets.first)
        #expect(asset.engineSubtitlesDisabled == false)
        // The bundled Noto faces, for VLC's own text renderers — in the user's design.
        #expect(asset.subtitleFontsDirectory == VLCSubtitleFonts.directory(for: .sans))
        #expect(asset.subtitleFontFamily == VLCSubtitleFonts.freetypeFamily(for: .sans))

        let embedded = SubtitleTrack(id: .vlc("vlc-s0"), displayName: "English",
                                     languageCode: "en", isForced: false)
        engine.push(.ready(duration: CMTime(seconds: 3600, preferredTimescale: 600),
                           tracks: TrackInventory(audio: [], subtitles: [embedded])))
        try await engine.settle()

        let track = try #require(vm.availableSubtitleTracks.first { $0.id == .vlc("vlc-s0") })
        await vm.selectSubtitleTrack(track)

        #expect(engine.selectedSubtitleTrackID == .vlc("vlc-s0"))
        #expect(vm.subtitleRenderer == nil)   // nothing client-side draws an embedded SMB track
    }

    /// VLC draws SMB embedded text itself, so the design has to reach it through the
    /// asset — the client renderer's live style push never runs for those tracks.
    /// Both knobs are libvlc MEDIA options, read once when the decoder is built.
    @Test("SMB: the asset's font directory and family follow the user's design")
    func smbAssetFollowsTheFontDesign() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        let vm = makeVM(reporting: StubPlaybackReporting(), engine: engine,
                        subtitleStyle: { .standard.with { $0.fontDesign = .serif } })

        await vm.start(smbItem: smbItem())

        let asset = try #require(engine.loadedAssets.first)
        #expect(asset.subtitleFontFamily == VLCSubtitleFonts.freetypeFamily(for: .serif))
        #expect(asset.subtitleFontsDirectory == VLCSubtitleFonts.directory(for: .serif))
    }

    /// The whole point of the instance-argument move: VLC's freetype renderer belongs to
    /// the video output, whose variables inherit from the libvlc INSTANCE — so the family
    /// and the look have to be arguments the player is BUILT with. A media option here is
    /// read by nobody, which is how the renderer sat on its own `Helvetica Neue` default.
    @Test("SMB: the subtitle look reaches the engine as libvlc instance arguments")
    func smbSubtitleLookRidesInstanceArguments() async throws {
        let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
        nonisolated(unsafe) var handed: [String]?
        let vm = makeVM(reporting: StubPlaybackReporting(), engine: engine,
                        observeLibraryOptions: { handed = $0 })

        await vm.start(smbItem: smbItem())

        let options = try #require(handed)
        #expect(options.contains("--freetype-font=\(VLCSubtitleFonts.freetypeFamily(for: .sans))"))
        #expect(options.contains { $0.hasPrefix("--freetype-rel-fontsize=") })
        // The credentials this item carries are MEDIA options and must not be promoted to
        // instance arguments, where they would outlive the input.
        #expect(options.contains { $0.contains("smb-pwd") } == false)
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
        engine.push(.playing(5, duration: .seconds(6000)))
        try await engine.settle()
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
        try await engine.settle()

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
        engine.push(.playing(10, duration: .seconds(6000)))
        engine.push(.playing(20, duration: .seconds(6000)))
        engine.push(.paused(20, duration: .seconds(6000)))
        engine.push(.ended)
        try await engine.settle()

        // resolved == nil is observable through the report contract: a Jellyfin
        // session would have fired start/progress/stopped beats; the SMB session
        // fires NONE (no resolved → no beat to build, no playSessionID to report).
        #expect(await reporting.events.isEmpty)
        #expect(await reporting.pings.isEmpty)
        #expect(await reporting.stoppedEncodings.isEmpty)
    }

    @Test("stop() tears the SMB session down cleanly: subtitleURLs cleared, no reporting")
    func stopTearsDownCleanly() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
            let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)

            let subURL = URL(string: "file:///tmp/Example.en.srt")!
            await vm.start(smbItem: smbItem(subtitleURLs: [0: subURL]))
            engine.push(.playing(15, duration: .seconds(6000)))
            try await engine.settle()
            #expect(vm.debugSubtitleURLs == [0: subURL])

            await vm.stop()

            #expect(engine.calls.contains("teardown"))
            #expect(vm.debugSubtitleURLs.isEmpty)
            // A session that never reported start must never report stop.
            #expect(await reporting.events.isEmpty)
            #expect(await reporting.stoppedEncodings.isEmpty)
        }
    }

    // MARK: - Local resume vs an untrusted (estimated) duration

    /// One position/duration shape, two verdicts, decided solely by whether the duration can be
    /// trusted. 5900s of a 6000s runtime is 98.3% — past the store's completion fraction, so it's
    /// the shape that clears a finished film AND the shape that would silently wipe real progress on
    /// an incomplete file, where VLCKitEngine synthesizes the "duration" from its read-rate estimate.
    @Test(
        "the completion-clear rule applies only to a duration the file can actually vouch for",
        arguments: [
            // (hasTrustworthyDuration, expected resume seconds after stop)
            (false, Double?.some(5_900)),
            (true, Double?.none),
        ]
    )
    func completionClearHonoursDurationTrust(trustworthy: Bool, expectedResume: Double?) async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
            let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)
            let id = ItemID(rawValue: "smb-duration-trust-\(trustworthy)")

            await vm.start(smbItem: smbItem(itemID: id, hasTrustworthyDuration: trustworthy))
            engine.push(.playing(5_900, duration: .seconds(6_000)))
            try await engine.settle()

            // stop()'s final save is unthrottled and inline-awaited — deterministic to assert
            // straight after, no throttle-window race.
            await vm.stop()

            let resumed = await store.resumeTime(for: id)
            if let expectedResume {
                #expect(abs(CMTimeGetSeconds(try #require(resumed)) - expectedResume) < 0.001)
            } else {
                #expect(resumed == nil)
            }
        }
    }

    @Test("a stale throttled save can't outrun .ended's terminal clear")
    func throttledSaveNeverOutrunsEndedClear() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine(id: .vlcKit, capabilities: .vlcKit)
            let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)
            let id = ItemID(rawValue: "smb-save-vs-clear")

            await vm.start(smbItem: smbItem(itemID: id))

            // The throttle window is wide open (first beat), so `.playing` spawns the untracked
            // save `.ended` must now await. Before the fix, the save Task's actor hop could lose
            // a race against `.ended`'s clear() — landing after it and resurrecting this position.
            engine.push(.playing(100, duration: .seconds(6_000)))
            engine.push(.ended)
            try await engine.settle()

            #expect(await store.resumeTime(for: id) == nil)
        }
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

        engine.push(.playing(5, duration: .seconds(6000)))
        try await engine.settle()
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
}

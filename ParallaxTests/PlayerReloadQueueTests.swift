import Foundation
import CoreMedia
import Testing
@testable import Parallax
import ParallaxPlayback
import ParallaxPlaybackTestSupport
@testable import ParallaxJellyfin
@testable import ParallaxCore

/// One reload's ask, as the server sees it. Reloads are only distinguishable by what they
/// REQUEST (the fake resolve hands back a fixed asset), so this is the ledger every case
/// below asserts on. File scope, not nested: the recorder runs inside `resolve`, off the
/// suite's MainActor.
private struct ResolveAsk: Equatable, CustomStringConvertible {
    var start: Double?
    var audio: Int?
    var subtitle: Int?

    var description: String {
        let s = start.map { "\($0)" } ?? "—"
        return "(start: \(s), audio: \(audio.map(String.init) ?? "—"), subtitle: \(subtitle.map(String.init) ?? "—"))"
    }
}

private func ask(_ start: CMTime?, _ selection: StreamSelection?) -> ResolveAsk {
    ResolveAsk(start: start.map(CMTimeGetSeconds),
               audio: selection?.audioStreamIndex,
               subtitle: selection?.subtitleStreamIndex)
}

/// The sidecar URL the Nth resolve hands back, so a fetch can be attributed to the session
/// that opened it rather than to the track it belongs to.
private func sidecarURL(session: Int) -> URL {
    URL(string: "https://jf.example.com/Videos/movie-1/ms-1/Subtitles/1/Stream.vtt?session=\(session)")!
}

/// Everything the user does DURING an engine-reusing transcode reload.
///
/// The HUD stays live for the several seconds a reload takes, so a seek, an audio pick and a
/// subtitle pick can all land inside one. They used to reach three unrelated roads and the
/// loser was dropped on the floor; these hold them to the one rule that replaced them —
/// merge into `PendingReload`, reload once, settle every dimension, and let the LAST reload
/// of a run be the one that spends the intent.
@Suite("PlayerViewModel — actions during a reload", .serialized)
@MainActor
struct PlayerReloadQueueTests {

    // MARK: - A pick made during a reload rides that reload out

    @Test("an audio pick during a re-anchor reload rides it out: ONE further reload, carrying the seek target AND the new index")
    func audioPickDuringAReanchorMerges() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []
        nonisolated(unsafe) var persisted: [TrackSelectionUpdate] = []

        let (vm, _) = try await makeReanchorVM(
            at: 600,
            rememberTrackSelection: { persisted.append($0) },
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                await gate.wait()
                return PlayerFixtures.resolvedMultiTrackTranscode()
            }
        )
        let audio4 = try audioTrack(vm, 4)
        let standing = vm.selectedAudioTrack
        let seeking = try await startReload(gate, on: vm, "the seek never reached the reload") {
            await vm.commitSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectAudioTrack(audio4)
        // The label is optimistic from the tap, not from the landing: the menu must not
        // read the outgoing track for the seconds the merged reload takes.
        #expect(vm.selectedAudioTrack == audio4)
        #expect(vm.selectedAudioTrack != standing)

        await gate.open()
        await seeking.value

        #expect(asks == [ResolveAsk(),
                        ResolveAsk(start: 3_000, audio: 3, subtitle: 1),
                        ResolveAsk(start: 3_000, audio: 4, subtitle: 1)])
        #expect(vm.selectedAudioTrack == audio4)
        #expect(vm.trackSwitchFailure == nil)
        // The writer is fire-and-forget, so arrival is the assertion, not the tick it lands on.
        try await requireEventually(
            { persisted.contains { if case .audio = $0 { return true } else { return false } } },
            "the landed pick was never persisted"
        )
    }

    @Test("a scrub commit during an audio switch is queued, not dropped: one further reload AT the target on the new track")
    func scrubCommitDuringAnAudioSwitchIsQueued() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let audio4 = try audioTrack(vm, 4)
        let switching = try await startReload(gate, on: vm, "the switch never reached the reload") {
            await vm.selectAudioTrack(audio4)
        }

        await vm.commitSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        // The hold stands: the merged reload is going to honour this target, so the bar
        // keeps showing it instead of snapping back to the pre-scrub clock.
        #expect(vm.seekHold != nil)

        await gate.open()
        await switching.value

        #expect(asks == [ResolveAsk(),
                        ResolveAsk(start: 600, audio: 4, subtitle: 1),
                        ResolveAsk(start: 3_000, audio: 4, subtitle: 1)])
    }

    @Test("an audio pick and a burn-in pick made during one reload cost ONE further reload carrying both indices")
    func audioAndSubtitlePicksMergeIntoOneReload() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let audio5 = try audioTrack(vm, 5)
        let burnIn = try subtitleTrack(vm, 7)
        let seeking = try await startReload(gate, on: vm, "the seek never reached the reload") {
            await vm.commitSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectAudioTrack(audio5)
        await vm.selectSubtitleTrack(burnIn)

        await gate.open()
        await seeking.value

        #expect(asks == [ResolveAsk(),
                        ResolveAsk(start: 3_000, audio: 3, subtitle: 1),
                        ResolveAsk(start: 3_000, audio: 5, subtitle: 7)])
        #expect(vm.selectedAudioTrack == audio5)
        #expect(vm.selectedSubtitleTrack == burnIn)
    }

    @Test("two audio picks in one window: the SECOND reloads, and a fallback restores the selection that stood before the FIRST")
    func newestPickReloadsAndAFallbackRestoresTheOldest() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            // The merged reload's own re-resolve fails while the outgoing stream is still
            // mounted — the silent fallback, which owes the menu its pre-pick truth back.
            if asks.count == 3 { throw AppError.playback(.unsupportedFormat) }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let standing = try #require(vm.selectedAudioTrack)
        let audio4 = try audioTrack(vm, 4)
        let audio5 = try audioTrack(vm, 5)
        let seeking = try await startReload(gate, on: vm, "the seek never reached the reload") {
            await vm.commitSeek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectAudioTrack(audio4)
        await vm.selectAudioTrack(audio5)

        await gate.open()
        await seeking.value

        #expect(asks.map(\.audio) == [nil, 3, 5], "the superseded pick reloaded, or the merge never ran: \(asks)")
        #expect(vm.selectedAudioTrack == standing, "the label restored to the superseded pick, not the pre-pick track")
        let failure = try #require(vm.trackSwitchFailure)
        #expect(failure.requested == .audio(audio5))
        #expect(failure.fallback == .audio(standing))
    }

    @Test("a text-sub pick made during a reload activates against the NEW session's sidecar URL")
    func textSubPickDuringAReloadReadsTheNewSession() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []
        nonisolated(unsafe) var fetched: [URL] = []

        // No server default subtitle: nothing is fetched before the pick under test, so the
        // sidecar cache can't answer it and the URL really is re-read from the session.
        let (vm, _) = try await makeReanchorVM(
            at: 600,
            subtitleFetch: { fetched.append($0); return Data() },
            sidecarUp: false,
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                let session = asks.count
                await gate.wait()
                return PlayerFixtures.resolvedMultiTrackTranscode(
                    defaultSubtitleStreamIndex: nil,
                    chineseSidecarURL: sidecarURL(session: session)
                )
            }
        )
        let audio4 = try audioTrack(vm, 4)
        let text = try subtitleTrack(vm, 1)
        let switching = try await startReload(gate, on: vm, "the switch never reached the reload") {
            await vm.selectAudioTrack(audio4)
        }

        await vm.selectSubtitleTrack(text)

        await gate.open()
        await switching.value
        try await requireEventually({ !fetched.isEmpty }, "the sidecar was never fetched")

        #expect(fetched == [sidecarURL(session: 3)], "the sidecar activated against the outgoing session's URL")
        #expect(vm.selectedSubtitleTrack == text)
    }

    // MARK: - Transport intent rides through the reload

    @Test("a pause issued during an audio switch is honoured by the session that comes out of it")
    func pauseDuringASwitchSurvivesTheReload() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live
        let audio4 = try audioTrack(vm, 4)
        let switching = try await startReload(gate, on: vm, "the switch never reached the reload") {
            await vm.selectAudioTrack(audio4)
        }

        // The lock screen's pause, landing mid-reload. It must not be overwritten by the
        // reload's own mechanical resume.
        vm.setPlaying(false)

        await gate.open()
        await switching.value
        await vm.awaitTransportQuiescence()

        #expect(vm.desiredPlaying == false)
        #expect(engine.isPlayingNow == false)
    }

    /// The reload's own tail (`loadAndPlay`) commands the incoming engine from intent — but it
    /// runs BEFORE the drain has spent the intent, and the settle that follows it is seconds
    /// long on a text sub (an engine deselect, then a sidecar fetch). A pause pressed in THAT
    /// window met the mid-reload guard with nothing left to replay it.
    @Test("a pause issued while the reload SETTLES is flushed by the drain, not swallowed")
    func pauseDuringTheSettleSurvivesTheDrain() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600, sidecarUp: false, resolve: { _, _, _, _ in
            PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)
        })
        let engine = engines.live
        // An out-of-buffer seek with no sidecar up goes in-stream and dirties the timeline,
        // which is what makes the plain text pick below cost a reload.
        await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        let text = try subtitleTrack(vm, 1)
        engine.hold(.subtitleTrack)

        let picking = Task { @MainActor in await vm.selectSubtitleTrack(text) }
        try await requireEventually({ engine.hasParked(.subtitleTrack) },
                                    "the settle never reached the sidecar activation")

        vm.setPlaying(false)

        engine.release(.subtitleTrack)
        await picking.value
        await vm.awaitTransportQuiescence()

        #expect(vm.desiredPlaying == false)
        #expect(engine.isPlayingNow == false, "the pause landed in the settle window and was swallowed")
    }

    @Test("a pause issued during a FAILED switch is not overwritten by the fallback resume")
    func pauseDuringAFailedSwitchIsNotOverwritten() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            if asks.count == 2 { throw AppError.playback(.unsupportedFormat) }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let engine = engines.live
        let audio4 = try audioTrack(vm, 4)
        let switching = try await startReload(gate, on: vm, "the switch never reached the reload") {
            await vm.selectAudioTrack(audio4)
        }

        vm.setPlaying(false)

        await gate.open()
        await switching.value
        await vm.awaitTransportQuiescence()

        #expect(vm.trackSwitchFailure != nil, "the failed switch never surfaced")
        #expect(vm.desiredPlaying == false, "the fallback resume overwrote the user's pause")
        #expect(engine.isPlayingNow == false)
    }

    // MARK: - The view gate

    @Test("acceptsPlaybackCommands: locked on a cold start, open through a mid-session reload")
    func acceptsPlaybackCommandsSpansTheReloadButNotTheColdStart() async throws {
        let cold = ResolveGate()
        let switching = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []
        let engines = EngineLedger()

        let vm = makePlayerVM(
            resolve: { _, _, _, _ in
                asks.append(ResolveAsk())
                let call = asks.count
                if call == 1 { await cold.wait() }
                if call == 2 { await switching.wait() }
                return PlayerFixtures.resolvedMultiTrackTranscode()
            },
            engineFactory: { id, _ in engines.make(id) }
        )
        await cold.arm()

        // Cold start: no session, no track list, no duration — nothing exists to merge into.
        let starting = Task { @MainActor in await vm.start(item: PlayerFixtures.movieDetail()) }
        try await requireEventually({ vm.phase == .loading && asks.count == 1 }, "the start never reached resolve")
        #expect(vm.acceptsPlaybackCommands == false)

        await cold.open()
        await starting.value
        engines.live.push(.playing(600))
        try await engines.live.settle()
        #expect(vm.acceptsPlaybackCommands)

        let audio4 = try audioTrack(vm, 4)
        let picking = try await startReload(switching, on: vm, "the switch never reached the reload") {
            await vm.selectAudioTrack(audio4)
        }
        // Mid-session reload: the scrubber, the chips and the transport stay live because
        // whatever they issue merges into the reload that is already running.
        #expect(vm.phase == .loading)
        #expect(vm.acceptsPlaybackCommands)

        await switching.open()
        await picking.value
        engines.live.push(.playing(600))
        try await engines.live.settle()
        #expect(vm.acceptsPlaybackCommands)
    }

    /// The gap the flag exists for: `.completed` clears the drain's own state, but `phase`
    /// only leaves `.loading` on the NEW session's first live beat — hundreds of ms later on
    /// device. Acceptance keyed on the drain unmounted the chip row and folded a live scrub in
    /// exactly that window.
    @Test("acceptance and the live-frame scrim span the reload's TAIL, up to the new session's first beat")
    func acceptanceSpansTheReloadTail() async throws {
        let gate = ResolveGate()
        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, _, _ in
            await gate.wait()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let audio4 = try audioTrack(vm, 4)
        let switching = try await startReload(gate, on: vm, "the switch never reached the reload") {
            await vm.selectAudioTrack(audio4)
        }

        await gate.open()
        await switching.value

        // The drain has returned; nothing has beaten on the new session yet.
        #expect(vm.phase == .loading)
        #expect(vm.isMidSessionReload, "the live-frame scrim flipped to the cold-start one for the tail")
        #expect(vm.acceptsPlaybackCommands, "the HUD locked between the drain returning and the first beat")

        engines.live.push(.playing(600))
        try await engines.live.settle()
        #expect(vm.isMidSessionReload == false)
        #expect(vm.acceptsPlaybackCommands)
    }

    // MARK: - A reload that never lands owes back everything that rode it

    @Test("a pick made during a reload that FAILS gets its label back — and can be picked again")
    func pickDuringAFailedReloadRestoresItsLabel() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            // The re-anchor's own re-resolve fails with the outgoing stream still mounted.
            if asks.count == 2 { throw AppError.playback(.unsupportedFormat) }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let standing = try #require(vm.selectedAudioTrack)
        let audio4 = try audioTrack(vm, 4)
        let seeking = try await startReload(gate, on: vm, "the seek never reached the reload") {
            await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectAudioTrack(audio4)
        #expect(vm.selectedAudioTrack == audio4)   // optimistic while it is queued

        await gate.open()
        await seeking.value

        #expect(asks.count == 2, "the discarded pick reloaded anyway")
        #expect(vm.selectedAudioTrack == standing, "the discarded pick left its label on the menu")
        #expect(vm.trackSwitchFailure == nil, "a position-only reload reported a failure it never had")

        // The re-tap only passes `track != selectedAudioTrack` because the label went back.
        await vm.selectAudioTrack(audio4)
        #expect(asks.count == 3, "the re-tap was swallowed by the stale optimistic label")
        #expect(vm.selectedAudioTrack == audio4)
    }

    // MARK: - The in-flight merge outranks everything the reload changed under it

    @Test("a seek during a reload whose re-resolve came back DIRECT-PLAY still merges — the engine is mid-load")
    func seekDuringADirectPlayReloadMerges() async throws {
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            // The server is allowed to answer a reload with a direct-play stream, and it
            // lands in `resolved` BEFORE the engine has loaded it.
            if asks.count == 2 { return PlayerFixtures.resolvedVC1MKV(itemID: "movie-1") }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let outgoing = engines.live
        // A direct-play VC-1 stream routes to VLC, so the reload rebuilds — and the swap's
        // audio cut is the seam that holds a caller inside `loadAndPlay`.
        outgoing.hold(.endAudio)

        let seeking = Task { @MainActor in await vm.seek(to: CMTime(seconds: 1_000, preferredTimescale: 600)) }
        try await requireEventually({ outgoing.hasParked(.endAudio) }, "the reload never reached the engine swap")

        let merged = await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        #expect(merged, "the seek took the in-stream road against an engine mid-load")

        outgoing.release(.endAudio)
        await seeking.value

        #expect(asks.count == 3)
        #expect(asks.last == ResolveAsk(start: 3_000, audio: 3, subtitle: 1))
        #expect(engines.engines.allSatisfy { engine in !engine.calls.contains { $0.hasPrefix("seek(") } },
                "an engine was sought mid-reload")
    }

    // MARK: - The declined burn-in

    @Test("a burn-in the server declined yields to the text pick made during it — no rollback, no scrim")
    func declinedBurnInYieldsToANewerPick() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, sidecarUp: false, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            // The server accepts the burn-in request and quietly declines to paint it.
            return PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil,
                                                             burnInDeliveryMethod: nil)
        })
        let burnIn = try subtitleTrack(vm, 7)
        let text = try subtitleTrack(vm, 1)
        let picking = try await startReload(gate, on: vm, "the burn-in pick never reached the reload") {
            await vm.selectSubtitleTrack(burnIn)
        }

        await vm.selectSubtitleTrack(text)

        await gate.open()
        await picking.value

        #expect(asks.map(\.subtitle) == [nil, 7, 1], "the rollback overwrote the pick the user had moved to")
        #expect(vm.selectedSubtitleTrack == text)
        #expect(vm.trackSwitchFailure == nil, "the user had already moved off the burn-in")
    }

    @Test("when the rollback of a declined burn-in ALSO fails, the menu and the overlay land on the fallback")
    func declinedBurnInRollbackFailureRestoresTheFallback() async throws {
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(
            at: 600,
            subtitleFetch: { _ in Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nline\n".utf8) },
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                // The rollback's own re-resolve fails, with the declined session still mounted.
                if asks.count == 3 { throw AppError.playback(.unsupportedFormat) }
                return PlayerFixtures.resolvedMultiTrackTranscode(burnInDeliveryMethod: nil)
            }
        )
        let text = try subtitleTrack(vm, 1)
        let burnIn = try subtitleTrack(vm, 7)
        try #require(vm.selectedSubtitleTrack == text)

        await vm.selectSubtitleTrack(burnIn)

        #expect(asks.map(\.subtitle) == [nil, 7, 1])
        #expect(vm.selectedSubtitleTrack == text, "the declined burn-in stayed on the menu")
        // The overlay, not a round trip: the sidecar cache is keyed by media source + stream,
        // so re-activating a track fetched this session deliberately costs no fetch at all.
        try await requireEventually({ vm.sidecarSubtitleInfo != nil },
                                    "the fallback's overlay never came back")
        let failure = try #require(vm.trackSwitchFailure)
        #expect(failure.requested == .subtitle(burnIn))
        #expect(failure.fallback == .subtitle(text))
    }

    // MARK: - Only the LAST reload of a run settles

    @Test("a text pick superseded by Off during its own reload is never fetched, and the overlay ends clear")
    func offQueuedDuringATextReloadNeverFetchesTheSupersededTrack() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []
        nonisolated(unsafe) var fetched: [URL] = []

        let (vm, _) = try await makeReanchorVM(
            at: 600,
            subtitleFetch: { fetched.append($0); return Data() },
            sidecarUp: false,
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                await gate.wait()
                return PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)
            }
        )
        let text = try subtitleTrack(vm, 1)
        // The dirty timeline is what makes a plain text pick cost a reload.
        await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        let picking = try await startReload(gate, on: vm, "the text pick never reached the reload") {
            await vm.selectSubtitleTrack(text)
        }

        await vm.selectSubtitleTrack(nil)

        await gate.open()
        await picking.value

        #expect(asks.map(\.subtitle) == [nil, 1, -1])
        #expect(fetched.isEmpty, "the superseded track's overlay was installed anyway")
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(vm.sidecarSubtitleInfo == nil, "the queued Off never cleared the overlay")
    }

    @Test("a seek merged into a text-sub reload fetches ONCE, against the session the LAST reload opened")
    func seekMergedIntoATextReloadFetchesOnceAfterTheLastReload() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []
        nonisolated(unsafe) var fetched: [URL] = []

        let (vm, _) = try await makeReanchorVM(
            at: 600,
            subtitleFetch: { fetched.append($0); return Data() },
            sidecarUp: false,
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                let session = asks.count
                await gate.wait()
                return PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil,
                                                                 chineseSidecarURL: sidecarURL(session: session))
            }
        )
        let text = try subtitleTrack(vm, 1)
        await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))   // dirties the timeline
        let picking = try await startReload(gate, on: vm, "the text pick never reached the reload") {
            await vm.selectSubtitleTrack(text)
        }

        let merged = await vm.seek(to: CMTime(seconds: 4_200, preferredTimescale: 600))
        #expect(merged)

        await gate.open()
        await picking.value
        try await requireEventually({ !fetched.isEmpty }, "the sidecar was never fetched")

        #expect(asks.count == 3)
        #expect(asks.last?.start == 4_200)
        #expect(fetched == [sidecarURL(session: 3)], "the intermediate session's URL was fetched between reloads")
    }

    // MARK: - A landing reload does not own a menu it is not carrying

    @Test("a pick queued during R1 owns the menu through R1's LANDING")
    func aQueuedPickOutlivesTheLandingOfTheReloadItWasMadeIn() async throws {
        let first = ResolveGate()
        let landing = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            let call = asks.count
            if call == 2 {
                await first.wait()
                // R1's landing rebuilds the menus; park what follows it so the menu can be
                // read exactly where it used to be rewritten from the outgoing indices.
                await landing.arm()
            }
            if call >= 3 { await landing.wait() }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let audio4 = try audioTrack(vm, 4)
        let seeking = try await startReload(first, on: vm, "the seek never reached the reload") {
            await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectAudioTrack(audio4)
        await first.open()
        try await requireEventually({ asks.count == 3 }, "the merged reload never started")

        #expect(vm.selectedAudioTrack == audio4, "R1's landing rewrote the menu from the indices it resolved with")

        await landing.open()
        await seeking.value
        #expect(vm.selectedAudioTrack == audio4)
    }

    @Test("a reload carrying BOTH a seek and an audio pick reads as the audio switch it is")
    func mergedSeekAndAudioReadsAsAnAudioSwitch() async throws {
        let first = ResolveGate()
        let landing = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            let call = asks.count
            if call == 2 {
                await first.wait()
                await landing.arm()
            }
            if call >= 3 { await landing.wait() }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let audio4 = try audioTrack(vm, 4)
        let seeking = try await startReload(first, on: vm, "the seek never reached the reload") {
            await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectAudioTrack(audio4)
        await first.open()
        try await requireEventually({ asks.count == 3 }, "the merged reload never started")

        // The scrim over a merged reload names the track: the seek is incidental, the switch
        // is the several-second thing the user is waiting on.
        #expect(vm.loaderTitle == PlayerViewModel.LoaderCaption.switchingAudio)
        #expect(vm.loaderSubtitle == audio4.displayName)

        await landing.open()
        await seeking.value
    }

    // MARK: - Changing your mind back

    @Test("picking back to the track that is still playing cancels the queued dimension instead of reloading to it")
    func pickingBackToTheStandingTrackCancelsTheDimension() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let standingAudio = try #require(vm.selectedAudioTrack)
        let standingSubtitle = try #require(vm.selectedSubtitleTrack)
        let audio4 = try audioTrack(vm, 4)
        let burnIn = try subtitleTrack(vm, 7)
        let seeking = try await startReload(gate, on: vm, "the seek never reached the reload") {
            await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectAudioTrack(audio4)
        await vm.selectAudioTrack(standingAudio)
        await vm.selectSubtitleTrack(burnIn)
        await vm.selectSubtitleTrack(standingSubtitle)

        #expect(vm.selectedAudioTrack == standingAudio)
        #expect(vm.selectedSubtitleTrack == standingSubtitle)

        await gate.open()
        await seeking.value

        #expect(asks == [ResolveAsk(), ResolveAsk(start: 3_000, audio: 3, subtitle: 1)],
                "a reload was spent going back to where the stream already was")
    }

    // MARK: - The drain dies with its session

    /// Auto-advance reaches `stop()` through `resetForReplay`, which disarms the exit fence
    /// again — so `isExiting` alone cannot tell a reload parked across the handoff that its
    /// session is gone. It used to wake up inside the NEXT episode and load the previous one
    /// into its engine.
    @Test("a reload parked across an episode handoff writes nothing into the session that replaced it")
    func aParkedReloadWritesNothingIntoTheReplacementSession() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [String] = []
        let engines = EngineLedger()

        let vm = makePlayerVM(
            resolve: { id, _, _, _ in
                asks.append(id.rawValue)
                // Only the reload parks; the replacement episode's own resolve passes through.
                if asks.count == 2 { await gate.wait() }
                return PlayerFixtures.resolvedMultiTrackTranscode()
            },
            engineFactory: { id, _ in engines.make(id) },
            fetchDetail: { id in PlayerFixtures.episodeDetail(id: id.rawValue) },
            fetchAdjacent: { _, _ in AdjacentEpisodes(previous: nil, next: PlayerFixtures.episode(id: "ep-2")) }
        )
        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-1"))
        engines.live.push(.playing(600))
        try await engines.live.settle()
        try await requireEventually({ vm.adjacentEpisodes.next != nil }, "adjacency never arrived")

        let audio5 = try audioTrack(vm, 5)
        let switching = try await startReload(gate, on: vm, "the switch never reached the reload") {
            await vm.selectAudioTrack(audio5)
        }

        // The handoff, landing while the reload is parked.
        await vm.playNextEpisode()
        let replacement = engines.live
        replacement.push(.playing(0))
        try await replacement.settle()
        try #require(vm.phase == .playing)

        await gate.open()
        await switching.value

        #expect(asks == ["ep-1", "ep-1", "ep-2"], "the stale drain resolved again")
        #expect(engines.count == 2)
        #expect(replacement.loadedAssets.count == 1, "the stale reload loaded the previous episode's stream")
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(3),
                "the stale drain wrote the previous episode's pick into the new menu")
        #expect(vm.phase == .playing)
    }
    // MARK: - A run that never lands owes the selection that stood before its FIRST pick

    /// `settle` puts the FAILED intent's `previous` back, and the drain then put the QUEUED
    /// intent's back over it — but the queued pick was made against the in-flight one, so its
    /// `previous` is the track that never played. The menu ended on it while the scrim said
    /// otherwise, and the re-tap died on `track != selectedAudioTrack`.
    @Test("a failed run restores the audio that stood before its FIRST pick, not the one in flight")
    func aFailedRunRestoresTheAudioFromBeforeTheRun() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            await gate.wait()
            // The FIRST pick's own reload falls back, with a second pick already queued.
            if asks.count == 2 { throw AppError.playback(.unsupportedFormat) }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let standing = try #require(vm.selectedAudioTrack)
        let audio4 = try audioTrack(vm, 4)
        let audio5 = try audioTrack(vm, 5)

        let switching = try await startReload(gate, on: vm, "the pick never reached the reload") {
            await vm.selectAudioTrack(audio4)
        }
        await vm.selectAudioTrack(audio5)

        await gate.open()
        await switching.value

        #expect(asks.count == 2, "the queued pick reloaded against the stream the fallback resumed")
        #expect(vm.selectedAudioTrack == standing,
                "the menu kept the in-flight pick — a track that never played")
        let failure = try #require(vm.trackSwitchFailure)
        #expect(failure.requested == .audio(audio4))
        #expect(failure.fallback == .audio(standing))

        // Only reachable because the label went all the way back.
        await vm.selectAudioTrack(audio4)
        #expect(asks.count == 3, "the re-pick was swallowed by a stale optimistic label")
    }

    /// The subtitle half, where the overlay is the visible proof: Off queued during the
    /// burn-in's own reload carries `previous: burn-in`, so restoring it left the menu on a
    /// burn-in nothing was painting and the text overlay under a wrong checkmark.
    @Test("a failed run restores the subtitle — and the overlay — from before its FIRST pick")
    func aFailedRunRestoresTheSubtitleFromBeforeTheRun() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(
            at: 600,
            subtitleFetch: { _ in Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nline\n".utf8) },
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                await gate.wait()
                if asks.count == 2 { throw AppError.playback(.unsupportedFormat) }
                return PlayerFixtures.resolvedMultiTrackTranscode()
            }
        )
        let text = try subtitleTrack(vm, 1)
        let burnIn = try subtitleTrack(vm, 7)
        try #require(vm.selectedSubtitleTrack == text)
        try await requireEventually({ vm.sidecarSubtitleInfo != nil }, "the fixture's overlay never came up")

        let picking = try await startReload(gate, on: vm, "the burn-in pick never reached the reload") {
            await vm.selectSubtitleTrack(burnIn)
        }
        await vm.selectSubtitleTrack(nil)   // Off, queued behind the burn-in

        await gate.open()
        await picking.value

        #expect(asks.count == 2, "the queued Off reloaded against the stream the fallback resumed")
        #expect(vm.selectedSubtitleTrack == text, "the menu kept the burn-in nothing was painting")
        try await requireEventually({ vm.sidecarSubtitleInfo != nil },
                                    "the text overlay that was up before the run never came back")
        let failure = try #require(vm.trackSwitchFailure)
        #expect(failure.requested == .subtitle(burnIn))
        #expect(failure.fallback == .subtitle(text))
    }

    // MARK: - The reload's PRELUDE belongs to its own session too

    /// The fences used to start at `beginPlayback`; the prelude before it — the silence, the
    /// encode kill, the stop report — wrote `isMidSessionReload`, `.loading`, `bufferedTo` and
    /// the reporting flags with nothing checking whose session it was writing into. A reload
    /// parked there across an episode handoff put a spinner over playing video and re-armed
    /// PlaybackStart on a session that had already reported it.
    @Test("a reload parked in its PRELUDE across an episode handoff writes nothing into the replacement")
    func aReloadParkedInThePreludeWritesNothingIntoTheReplacement() async throws {
        nonisolated(unsafe) var asks: [String] = []
        let engines = EngineLedger()

        let vm = makePlayerVM(
            resolve: { id, _, _, _ in
                asks.append(id.rawValue)
                return PlayerFixtures.resolvedMultiTrackTranscode()
            },
            engineFactory: { id, _ in engines.make(id) },
            fetchDetail: { id in PlayerFixtures.episodeDetail(id: id.rawValue) },
            fetchAdjacent: { _, _ in AdjacentEpisodes(previous: nil, next: PlayerFixtures.episode(id: "ep-2")) }
        )
        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-1"))
        let outgoing = engines.live
        outgoing.push(.playing(600))
        try await outgoing.settle()
        try await requireEventually({ vm.adjacentEpisodes.next != nil }, "adjacency never arrived")

        let audio5 = try audioTrack(vm, 5)
        // The prelude's FIRST await, before it has written a single flag.
        outgoing.hold(.silence)
        let switching = Task { @MainActor in await vm.selectAudioTrack(audio5) }
        try await requireEventually({ outgoing.hasParked(.silence) }, "the reload never reached its prelude")

        await vm.playNextEpisode()
        let replacement = engines.live
        replacement.push(.playing(0))
        try await replacement.settle()
        try #require(vm.phase == .playing)

        outgoing.release(.silence)
        await switching.value

        #expect(asks == ["ep-1", "ep-2"], "the stale reload re-resolved the previous episode")
        #expect(replacement.loadedAssets.count == 1, "the stale reload loaded into the replacement")
        #expect(vm.phase == .playing, "the stale prelude put a loading scrim over playing video")
        #expect(vm.isMidSessionReload == false)
        #expect(vm.selectedAudioTrack?.id == .jellyfinStream(3),
                "the stale reload wrote the previous episode's pick into the new menu")
    }

    /// `activateSidecarSubtitle` awaits the engine deselect before it writes the index, the
    /// selection and the fetch. The drain's generation guards sit OUTSIDE `settle`, so that
    /// await was the one window a handoff could land in and have the previous item's subtitle
    /// written into the session that replaced it.
    @Test("a sidecar activation parked on the engine deselect writes nothing into the session that replaced it")
    func aParkedSidecarActivationWritesNothingIntoTheReplacementSession() async throws {
        nonisolated(unsafe) var asks: [String] = []
        nonisolated(unsafe) var fetched: [URL] = []
        let engines = EngineLedger()

        let vm = makePlayerVM(
            resolve: { id, _, _, _ in
                asks.append(id.rawValue)
                return PlayerFixtures.resolvedMultiTrackTranscode(
                    defaultSubtitleStreamIndex: nil,
                    chineseSidecarURL: sidecarURL(session: asks.count)
                )
            },
            engineFactory: { id, _ in engines.make(id) },
            fetchDetail: { id in PlayerFixtures.episodeDetail(id: id.rawValue) },
            subtitleFetch: { fetched.append($0); return Data() },
            fetchAdjacent: { _, _ in AdjacentEpisodes(previous: nil, next: PlayerFixtures.episode(id: "ep-2")) }
        )
        await vm.start(item: PlayerFixtures.episodeDetail(id: "ep-1"))
        let outgoing = engines.live
        outgoing.push(.playing(600))
        try await outgoing.settle()
        try await requireEventually({ vm.adjacentEpisodes.next != nil }, "adjacency never arrived")

        let text = try subtitleTrack(vm, 1)
        outgoing.hold(.subtitleTrack)
        let picking = Task { @MainActor in await vm.selectSubtitleTrack(text) }
        try await requireEventually({ outgoing.hasParked(.subtitleTrack) },
                                    "the pick never reached the engine deselect")

        await vm.playNextEpisode()
        let replacement = engines.live
        replacement.push(.playing(0))
        try await replacement.settle()
        try #require(vm.phase == .playing)

        outgoing.release(.subtitleTrack)
        await picking.value

        #expect(vm.selectedSubtitleTrack == nil, "the previous item's subtitle landed in the new session")
        #expect(fetched.isEmpty, "the stale activation fetched a sidecar against the replacement's session")
    }

    // MARK: - The declined burn-in's record belongs to the intent, not to the iteration

    /// The record used to be a drain local applied one iteration later, whatever that
    /// iteration turned out to be: an Off picked during the rollback landed successfully and
    /// still got the burn-in's failure scrim raised over it.
    @Test("a declined burn-in raises no scrim when the user picked Off during its rollback")
    func aDeclinedBurnInDropsItsRecordWhenTheRollbackIsSuperseded() async throws {
        let rollback = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            let call = asks.count
            // Park the ROLLBACK (call 3), which is the iteration the record used to ride.
            if call == 2 { await rollback.arm() }
            if call >= 3 { await rollback.wait() }
            return PlayerFixtures.resolvedMultiTrackTranscode(burnInDeliveryMethod: nil)
        })
        let text = try subtitleTrack(vm, 1)
        let burnIn = try subtitleTrack(vm, 7)
        try #require(vm.selectedSubtitleTrack == text)

        let picking = Task { @MainActor in await vm.selectSubtitleTrack(burnIn) }
        try await requireEventually({ asks.count == 3 }, "the rollback never started")

        await vm.selectSubtitleTrack(nil)

        await rollback.open()
        await picking.value

        #expect(asks.map(\.subtitle) == [nil, 7, 1, -1])
        #expect(vm.selectedSubtitleTrack == nil)
        #expect(vm.trackSwitchFailure == nil,
                "the burn-in's scrim rose over the Off that landed after it")
    }

    // MARK: - The loader caption reads the reload it is actually covering

    /// `isReanchoring` derived from `reloadInFlight`, which the drain nils while `phase` is
    /// still `.loading` — so the last few hundred ms of every scrub read "Switching audio ·
    /// <track>" over a re-anchor that switched nothing.
    @Test("a pure re-anchor reads as buffering through its TAIL, not as an audio switch")
    func aReanchorTailStaysBuffering() async throws {
        let (vm, engines) = try await makeReanchorVM(at: 600)

        await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))

        // The drain has returned; nothing has beaten on the new session yet.
        #expect(vm.phase == .loading)
        #expect(vm.isMidSessionReload)
        #expect(vm.loaderTitle == PlayerViewModel.LoaderCaption.buffering,
                "the tail of a scrub read as an audio switch")
        #expect(vm.loaderSubtitle == nil)

        engines.live.push(.playing(3_000))
        try await engines.live.settle()
        #expect(vm.isMidSessionReload == false)
    }

    // MARK: - The in-flight merge outranks the method the reload came back with

    /// `selectAudioTrack`'s twin of `seek(to:)`'s rule: a reload the server answers with a
    /// direct-play stream lands in `resolved` while `loadAndPlay` is still running, so
    /// reading `resolved?.method` re-points an engine that is mid-swap.
    @Test("an audio pick during a reload whose re-resolve came back DIRECT-PLAY still merges")
    func audioPickDuringADirectPlayReloadMerges() async throws {
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, engines) = try await makeReanchorVM(at: 600, resolve: { _, _, start, selection in
            asks.append(ask(start, selection))
            if asks.count == 2 { return PlayerFixtures.resolvedVC1MKV(itemID: "movie-1") }
            return PlayerFixtures.resolvedMultiTrackTranscode()
        })
        let audio4 = try audioTrack(vm, 4)
        let outgoing = engines.live
        // A direct-play VC-1 stream routes to VLC, so the reload rebuilds — and the swap's
        // audio cut is the seam that holds a caller inside `loadAndPlay`.
        outgoing.hold(.endAudio)

        let seeking = Task { @MainActor in await vm.seek(to: CMTime(seconds: 1_000, preferredTimescale: 600)) }
        try await requireEventually({ outgoing.hasParked(.endAudio) }, "the reload never reached the engine swap")

        await vm.selectAudioTrack(audio4)
        #expect(vm.selectedAudioTrack == audio4)

        outgoing.release(.endAudio)
        await seeking.value

        #expect(asks.count == 3)
        #expect(asks.last?.audio == 4, "the pick was answered against the half-loaded session")
        #expect(engines.engines.allSatisfy { engine in
            !engine.calls.contains { $0.hasPrefix("setAudioTrack(") }
        }, "an engine was re-pointed mid-reload")
    }

    // MARK: - Re-tapping the row that is already checked

    @Test("re-tapping the checked subtitle row during a reload spends no reload and keeps the overlay")
    func reTappingTheCheckedSubtitleRowMidReloadIsANoOp() async throws {
        let gate = ResolveGate()
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(
            at: 600,
            subtitleFetch: { _ in Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nline\n".utf8) },
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                await gate.wait()
                return PlayerFixtures.resolvedMultiTrackTranscode()
            }
        )
        let text = try subtitleTrack(vm, 1)
        try #require(vm.selectedSubtitleTrack == text)
        try await requireEventually({ vm.sidecarSubtitleInfo != nil }, "the fixture's overlay never came up")

        let seeking = try await startReload(gate, on: vm, "the seek never reached the reload") {
            await vm.seek(to: CMTime(seconds: 3_000, preferredTimescale: 600))
        }

        await vm.selectSubtitleTrack(text)
        #expect(vm.sidecarSubtitleInfo != nil, "the re-tap dropped the overlay it was already showing")

        await gate.open()
        await seeking.value

        #expect(asks == [ResolveAsk(), ResolveAsk(start: 3_000, audio: 3, subtitle: 1)],
                "a reload was spent re-picking the row that was already checked")
    }

    @Test("an explicit Off on a transcode the server resolved with NO subtitle pins the sentinel the next reload carries")
    func explicitOffPinsTheNoneSentinel() async throws {
        nonisolated(unsafe) var asks: [ResolveAsk] = []

        let (vm, _) = try await makeReanchorVM(
            at: 600,
            sidecarUp: false,
            resolve: { _, _, start, selection in
                asks.append(ask(start, selection))
                return PlayerFixtures.resolvedMultiTrackTranscode(defaultSubtitleStreamIndex: nil)
            }
        )
        // Off is checked, but only because the server was left to choose and chose nothing.
        try #require(vm.selectedSubtitleTrack == nil)

        await vm.selectSubtitleTrack(nil)
        await vm.selectAudioTrack(try audioTrack(vm, 4))

        #expect(asks.last == ResolveAsk(start: 600, audio: 4, subtitle: -1),
                "the explicit Off was treated as a re-tap, and the reload let the server choose again")
    }
}

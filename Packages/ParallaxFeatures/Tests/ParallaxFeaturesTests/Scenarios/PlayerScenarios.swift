import CoreMedia
import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import ParallaxPlayback
import Testing

@MainActor
@Suite("Player", .timeLimit(.minutes(1)))
struct PlayerScenarios {
    @Test("the server a video plays from revoking its token closes the player and tears its engine down")
    func serverSwitchClosesThePlayer() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films", minutes: 170)
        let attic = FakeJellyfinServer(name: "Attic").user("bo")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        try await world.openPlayer()
        let runtime = Duration.seconds(170 * 60)
        try await world.streamPlays(at: .seconds(600), of: runtime)
        try await world.until { den.playbackReports.count == 1 }

        den.revokeAllTokens()
        world.clock.advance(by: .seconds(10))
        // Not `streamPlays`: the report this beat sends closes the player, which may stop
        // consuming beats before it settles.
        world.engine.push(.playing(610, duration: .seconds(170 * 60)))

        try await world.until { world.app.router.activeServerID == ServerID(rawValue: attic.id) }
        #expect(world.app.playback.request == nil)
        try await world.until { world.engine.calls.contains("teardown") }
        #expect(world.engines.count == 1)
    }

    @Test("a player dismissed while it is still being built never starts playback")
    func dismissWhileBuildingNeverStarts() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        let request = try #require(world.app.playback.request)
        var ended = false
        let app = world.app
        let mounting = Task {
            await app.runPlayer(for: request, subtitleSurface: { PlayerFixtures.phoneSurface }) { _ in }
            ended = true
        }
        defer { mounting.cancel() }

        world.app.playback.dismiss()

        try await world.until { () async in ended || world.engines.count > 0 }
        #expect(world.engines.count == 0)
        #expect(den.playbackRequests.isEmpty)
    }

    @Test("a display that decodes Dolby Vision, connected between two plays, is offered to the server on the second")
    func hdrEligibilityChangeReachesTheNextPlay() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let heat = ItemID(rawValue: den.itemID(of: "Heat"))
        world.app.playback.play(heat, in: try await world.session(on: den))
        try await world.openPlayer()
        await world.closePlayer()

        try await world.connectDisplay(playing: .dolbyVision)
        world.app.playback.play(heat, in: try await world.session(on: den))
        try await world.clock.waitForSleep(dueIn: .milliseconds(600))
        world.clock.advance(by: .milliseconds(600))
        try await world.until { world.app.playback.request != nil }
        try await world.openPlayer()

        #expect(den.playbackRequests.map(\.acceptsDolbyVision) == [false, true])
    }

    @Test("a half-watched movie opens at its saved position, its progress reaches the server, and Home resumes where it was closed")
    func halfWatchedMovieResumesAndReportsItsStop() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170).watch("Heat", minutes: 42)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        let session = try await world.session(on: den)
        let tile = try #require(world.app.home?.continueWatching.first)
        guard case .play(let heat) = MediaTileTap.resolve(tile.item, on: session, moviePlays: true) else {
            Issue.record("a Continue Watching movie opened its detail instead of playing")
            return
        }
        world.app.playback.play(heat, in: session)

        let player = try await world.openPlayer()
        #expect(player.title == "Heat")
        #expect(den.playbackRequests == [FakeJellyfinServer.PlaybackRequest(item: "Heat", startSeconds: 2520)])
        let asset = try #require(world.engine.loadedAssets.last)
        #expect(asset.url.path == "/Videos/\(heat.rawValue)/stream.mp4")
        #expect(asset.startTime == .seconds(2520))

        try await world.streamIsReady(duration: .seconds(170 * 60))
        try await world.streamPlays(at: .seconds(2520), of: .seconds(170 * 60))
        try await world.streamPlays(at: .seconds(2580), of: .seconds(170 * 60))
        #expect(player.phase == .playing)
        try await world.until { den.playbackReports.count == 2 }
        #expect(den.playbackReports == [
            FakeJellyfinServer.PlaybackReport(.started, "Heat", at: 2520),
            FakeJellyfinServer.PlaybackReport(.progress, "Heat", at: 2580),
        ])

        await world.closePlayer()
        #expect(den.playbackReports.last == FakeJellyfinServer.PlaybackReport(.stopped, "Heat", at: 2580))
        try await world.until { world.minutesWatched("Heat") == 43 }
    }

    @Test("while a movie plays, its progress reaches the server at most once every 10 seconds")
    func progressReportsAreThrottledOnTheClock() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: session)
        try await world.openPlayer()
        let runtime = Duration.seconds(170 * 60)

        try await world.streamIsReady(duration: runtime)
        try await world.streamPlays(at: .seconds(600), of: runtime)
        try await world.streamPlays(at: .seconds(601), of: runtime)
        world.clock.advance(by: .seconds(9))
        try await world.streamPlays(at: .seconds(610), of: runtime)
        world.clock.advance(by: .seconds(1))
        try await world.streamPlays(at: .seconds(611), of: runtime)

        try await world.until { den.playbackReports.count == 3 }
        #expect(den.playbackReports == [
            FakeJellyfinServer.PlaybackReport(.started, "Heat", at: 600),
            FakeJellyfinServer.PlaybackReport(.progress, "Heat", at: 601),
            FakeJellyfinServer.PlaybackReport(.progress, "Heat", at: 611),
        ])
    }

    @Test("Play from Beginning on a half-watched movie starts it at zero")
    func playFromBeginningStartsAtZero() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170).watch("Heat", minutes: 42)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        let heat = ItemID(rawValue: den.itemID(of: "Heat"))
        await world.app.perform(.playFromBeginning(heat), on: session)

        try await world.openPlayer()

        #expect(den.playbackRequests == [FakeJellyfinServer.PlaybackRequest(item: "Heat", startSeconds: nil)])
        #expect(world.engine.loadedAssets.last?.startTime == nil)
    }

    @Test("an episode that plays to its end rolls into the next one, and the title changes with it")
    func endedEpisodeAdvancesToTheNext() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Shows", of: .shows)
            .series("Severance", in: "Shows", episodes: [2])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Severance S1E1")), in: session)

        let player = try await world.openPlayer()
        #expect(player.title == "1. Severance S1E1")
        try await world.until { player.nextEpisode?.name == "Severance S1E2" }
        try await world.streamPlays(at: .seconds(49 * 60), of: .seconds(50 * 60))

        world.streamEnds()

        try await world.until { player.title == "2. Severance S1E2" && world.engines.count == 2 }
        try await world.until { world.engine.calls.contains("play") }
        #expect(player.phase == .loading)
        #expect(den.playbackRequests.map(\.item) == ["Severance S1E1", "Severance S1E2"])
        #expect(den.playbackReports.contains(FakeJellyfinServer.PlaybackReport(.stopped, "Severance S1E1", at: 49 * 60)))
        #expect(world.app.playback.request != nil)
    }

    @Test("the last episode of a series playing to its end closes the player instead of advancing")
    func endedFinaleClosesThePlayer() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Shows", of: .shows)
            .series("Severance", in: "Shows", episodes: [2])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Severance S1E2")), in: session)

        let player = try await world.openPlayer()
        try await world.until { player.previousEpisode?.name == "Severance S1E1" }
        #expect(player.nextEpisode == nil)
        try await world.streamPlays(at: .seconds(49 * 60), of: .seconds(50 * 60))

        world.streamEnds()

        try await world.until { world.app.playback.request == nil }
        #expect(player.playbackDidComplete)
        #expect(world.engines.count == 1)
        #expect(den.playbackRequests.map(\.item) == ["Severance S1E2"])
        try await world.until { world.engine.calls.contains("teardown") }
        try await world.until { den.playbackReports.last?.kind == .stopped }
        #expect(den.playbackReports.last == FakeJellyfinServer.PlaybackReport(.stopped, "Severance S1E2", at: 49 * 60))
    }

    @Test("closing the player while it hands off to the next episode closes it for good")
    func closeDuringEpisodeHandoffStaysClosed() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Shows", of: .shows)
            .series("Severance", in: "Shows", episodes: [2])
            .streams("Severance S1E1", by: .transcode)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Severance S1E1")), in: session)
        weak var player = try await world.openPlayer()
        try await world.until { player?.nextEpisode?.name == "Severance S1E2" }
        try await world.streamPlays(at: .seconds(49 * 60), of: .seconds(50 * 60))
        den.holdResponses(to: .encodingKills)
        world.streamEnds()
        try await world.until { den.heldResponseCount == 1 }

        let closing = world.dismissPlayer()
        den.releaseResponses()
        await closing.value
        try await world.until { () async in player == nil }

        #expect(world.engines.count == 1)
        #expect(den.playbackRequests.map(\.item) == ["Severance S1E1"])
        #expect(world.audioSession.calls == [.activate, .deactivate])
    }

    @Test("a player whose view goes away without a dismissal still ends its audio")
    func viewGoingAwayEndsTheAudio() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films", minutes: 170)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        let request = try #require(world.app.playback.request)
        let app = world.app
        let mounted = Task {
            await app.runPlayer(for: request, subtitleSurface: { PlayerFixtures.phoneSurface }) { _ in }
        }
        try await world.until { world.engines.count == 1 && world.engine.calls.contains("play") }
        try await world.streamPlays(at: .seconds(600), of: .seconds(170 * 60))

        mounted.cancel()
        await mounted.value

        #expect(world.engine.calls.filter { ["endAudio", "teardown"].contains($0) } == ["endAudio", "teardown"])
        #expect(world.audioSession.calls == [.activate, .deactivate])
        #expect(den.playbackReports.last == FakeJellyfinServer.PlaybackReport(.stopped, "Heat", at: 600))
    }

    @Test("a closed player's audio is gone before the next pick plays, while its stop report is still on the wire")
    func closedPlayersAudioEndsBeforeTheNextPlays() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170).movie("Ran", in: "Films", minutes: 162)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: session)
        try await world.openPlayer()
        try await world.streamPlays(at: .seconds(600), of: .seconds(170 * 60))
        try await world.until { den.playbackReports.count == 1 }
        den.holdResponses(to: .playbackStops)

        let closing = world.dismissPlayer()
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Ran")), in: session)
        try await world.until { den.heldResponseCount == 1 }
        try await world.clock.waitForSleep(dueIn: .milliseconds(600))
        world.clock.advance(by: .milliseconds(600))
        try await world.until { world.app.playback.request != nil }
        try await world.openPlayer()
        den.releaseResponses()
        await closing.value

        #expect(world.audioSession.calls == [.activate, .deactivate, .activate])
        #expect(den.playbackReports == [
            FakeJellyfinServer.PlaybackReport(.started, "Heat", at: 600),
            FakeJellyfinServer.PlaybackReport(.stopped, "Heat", at: 600),
        ])
    }

    @Test("closing the player re-reads Home's progress only once the server has the stop report")
    func homeRefreshesAfterTheStopReportLands() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170).watch("Heat", minutes: 42)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        try await world.openPlayer()
        let runtime = Duration.seconds(170 * 60)
        try await world.streamPlays(at: .seconds(2520), of: runtime)
        try await world.streamPlays(at: .seconds(2580), of: runtime)
        try await world.until { den.playbackReports.count == 2 }
        // Inside the 10 s progress throttle: only the stop report carries this position.
        try await world.streamPlays(at: .seconds(2700), of: runtime)
        den.holdResponses(to: .playbackStops)

        let closing = world.dismissPlayer()
        try await world.until { den.heldResponseCount == 1 }
        den.releaseResponses()
        await closing.value

        try await world.until { world.minutesWatched("Heat") == 45 }
    }

    @Test("inside the intro the player offers to skip it, and skipping lands just past it")
    func skipIntroSeeksPastIt() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170).intro(of: "Heat", from: 0, to: 90)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: session)
        let player = try await world.openPlayer()

        try await world.streamPlays(at: .seconds(30), of: .seconds(170 * 60))
        try await world.until { player.segmentPrompt != nil }
        guard case .skip(let intro)? = player.segmentPrompt else {
            Issue.record("the intro offered \(String(describing: player.segmentPrompt)) instead of Skip")
            return
        }
        #expect(intro.kind == .intro)
        #expect(intro.endSeconds == 90)

        await player.skipActiveSegment()
        try await world.engine.settle()

        #expect(world.engine.calls.contains("seek(90.0)"))
        #expect(player.flight == nil, "the bar never settled on the engine's landing")
        #expect(CMTimeGetSeconds(player.currentPosition) == 90)
        #expect(player.segmentPrompt == nil)
    }

    @Test("choosing another audio track on a transcode reloads the stream where it was, and the choice sticks")
    func audioSwitchOnATranscodeReloadsInPlace() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Ran", in: "Films", minutes: 162)
            .streams("Ran", by: .transcode, audio: [
                FakeJellyfinServer.AudioTrack(language: "jpn", title: "Japanese"),
                FakeJellyfinServer.AudioTrack(language: "eng", title: "English"),
            ])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Ran")), in: session)
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        #expect(player.availableAudioTracks.map(\.displayName) == ["Japanese", "English"])
        #expect(player.selectedAudioTrack?.displayName == "Japanese")
        let english = try #require(player.availableAudioTracks.last)

        await player.selectAudioTrack(english)

        #expect(den.playbackRequests == [
            FakeJellyfinServer.PlaybackRequest(item: "Ran", startSeconds: nil),
            FakeJellyfinServer.PlaybackRequest(item: "Ran", startSeconds: 600, audioStreamIndex: 2),
        ])
        #expect(world.engines.count == 1)
        #expect(world.engine.loadedAssets.last?.startTime == .seconds(600))
        #expect(player.selectedAudioTrack?.displayName == "English")
        #expect(player.loaderTitle == "Switching audio")

        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        #expect(player.phase == .playing)
        #expect(player.selectedAudioTrack?.displayName == "English")
    }

    @Test("after an in-place reload, a beat the replaced stream still had in flight doesn't move the player")
    func staleBeatAfterAnInPlaceReloadIsDropped() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Ran", in: "Films", minutes: 162)
            .streams("Ran", by: .transcode, audio: [
                FakeJellyfinServer.AudioTrack(language: "jpn", title: "Japanese"),
                FakeJellyfinServer.AudioTrack(language: "eng", title: "English"),
            ])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Ran")), in: session)
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        let replaced = world.engine.session
        await player.selectAudioTrack(try #require(player.availableAudioTracks.last))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))

        world.engine.push(.playing(30, duration: .seconds(162 * 60)), from: replaced)
        try await world.engine.settle()

        #expect(world.engines.count == 1)
        #expect(CMTimeGetSeconds(player.currentPosition) == 600)
        #expect(player.phase == .playing)
    }

    @Test("a film AVKit can't decode falls back to VLC at the same spot and plays")
    func undecodableFilmFallsBackToVLC() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films", minutes: 170)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: session)
        let player = try await world.openPlayer()
        #expect(world.engine.id == .avKit)
        try await world.streamPlays(at: .seconds(300), of: .seconds(170 * 60))
        let url = try #require(world.engine.loadedAssets.last?.url)

        world.streamFailsToDecode()

        try await world.until { world.engines.count == 2 && world.engine.calls.contains("play") }
        #expect(world.engine.id == .vlcKit)
        #expect(world.engine.loadedAssets.last?.url == url)
        #expect(world.engine.loadedAssets.last?.startTime == .seconds(300))
        try await world.streamPlays(at: .seconds(301), of: .seconds(170 * 60))
        #expect(player.phase == .playing)
    }

    @Test("choosing an external subtitle fetches it from the server and puts it on screen")
    func externalSubtitleIsFetchedAndRendered() async throws {
        let srt = "1\n00:00:01,000 --> 00:00:04,000\nThe heat is on.\n"
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170)
            .streams("Heat", subtitles: [FakeJellyfinServer.SubtitleTrack(language: "eng", title: "English", .srt(srt))])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: session)
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .seconds(1), of: .seconds(170 * 60))
        let english = try #require(player.availableSubtitleTracks.first)
        #expect(english.displayName == "English")

        await player.selectSubtitleTrack(english)

        try await world.until { player.subtitleRenderer != nil }
        #expect(player.selectedSubtitleTrack?.displayName == "English")
        #expect(player.sidecarSubtitleInfo?.format == .srt)
        #expect(player.sidecarSubtitleInfo?.byteCount == srt.utf8.count)
        #expect(player.loadingSubtitleTrackID == nil)
    }

    @Test("leaving a burned-in subtitle for Off asks the server for a fresh stream without it")
    func leavingABurnInReresolvesTheStream() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Ran", in: "Films", minutes: 162)
            .streams("Ran", by: .transcode, subtitles: [
                FakeJellyfinServer.SubtitleTrack(language: "eng", title: "English", .image),
            ])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Ran")), in: session)
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        let burnIn = try #require(player.availableSubtitleTracks.first)
        #expect(burnIn.isBurnedIn)

        await player.selectSubtitleTrack(burnIn)
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        #expect(player.selectedSubtitleTrack == burnIn)

        await player.selectSubtitleTrack(nil)

        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, 2, -1])
        #expect(den.playbackRequests.last?.startSeconds == 600)
        #expect(player.selectedSubtitleTrack == nil)
    }

    @Test("an SMB film's position survives a relaunch, and playing it again resumes there")
    func smbResumeSurvivesARelaunch() async throws {
        let nas = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media"])
        let ref = makeSMBRef(nas)
        let world = try await AppWorld.launch(savedSMB: [(nas, "hunter2")])
        world.nas.setFolder([SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 1, modifiedAt: nil)], share: "Media")
        world.nas.setContents(Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60)))
        let films = await world.openSMBFolder(ref, share: "Media")
        try await world.until { !films.isLoading }
        films.play(try #require(films.media.first))
        let player = try await world.openPlayer()
        #expect(player.title == "Heat")
        #expect(world.engine.loadedAssets.last?.startTime == nil)
        try await world.streamIsReady(duration: .seconds(7200))
        try await world.streamPlays(at: .seconds(1800), of: .seconds(7200))
        await world.closePlayer()

        await world.relaunch()
        let filmsAgain = await world.openSMBFolder(ref, share: "Media")
        try await world.until { !filmsAgain.isLoading }
        filmsAgain.play(try #require(filmsAgain.media.first))
        try await world.openPlayer()

        #expect(world.engine.loadedAssets.last?.startTime == .seconds(1800))
    }
}

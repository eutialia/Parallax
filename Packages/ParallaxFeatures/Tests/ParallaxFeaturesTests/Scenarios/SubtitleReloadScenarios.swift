import CoreMedia
import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import Testing

/// Subtitle picks made while a transcode is reloading. A reload takes seconds, and the menu stays
/// usable through it: picks made meanwhile wait for it, the newest one wins, and a failure puts
/// back what was on screen before the first of them.
@MainActor
@Suite("Subtitle picks during a reload", .timeLimit(.minutes(1)))
struct SubtitleReloadScenarios {
    private typealias Request = FakeJellyfinServer.PlaybackRequest
    private typealias Track = FakeJellyfinServer.SubtitleTrack

    private static let french = "1\n00:00:01,000 --> 00:00:04,000\nLe château brûle.\n"
    private static let frenchIndex = 4
    private static let pictureIndex = 5

    /// Ran by transcode, ten minutes in: Japanese, English and German audio, a French text
    /// subtitle and an English picture subtitle. With `frenchUp`, French is the user's remembered
    /// language and is on screen when the player opens.
    private func openRan(
        frenchUp: Bool, decliningBurnIn: Bool = false
    ) async throws -> (FakeJellyfinServer, AppWorld, PlayerViewModel) {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Ran", in: "Films", minutes: 162)
            .streams("Ran", by: .transcode, audio: [
                FakeJellyfinServer.AudioTrack(language: "jpn", title: "Japanese"),
                FakeJellyfinServer.AudioTrack(language: "eng", title: "English"),
                FakeJellyfinServer.AudioTrack(language: "deu", title: "German"),
            ], subtitles: [
                Track(language: "fra", title: "French", .srt(Self.french)),
                Track(language: "eng", title: "English", .image, isEmbedded: true),
            ])
        if frenchUp { den.subtitleLanguage("fra", for: "ana") }
        if decliningBurnIn { _ = den.declineBurnIn(of: "Ran") }
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Ran")), in: try await world.session(on: den))
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        if frenchUp {
            try await world.until { player.selectedSubtitleTrack?.displayName == "French" && player.subtitleRenderer != nil }
        }
        return (den, world, player)
    }

    private func subtitle(_ name: String, of player: PlayerViewModel) throws -> SubtitleTrack {
        try #require(player.availableSubtitleTracks.first { $0.displayName == name })
    }

    private func audio(_ name: String, of player: PlayerViewModel) throws -> AudioTrack {
        try #require(player.availableAudioTracks.first { $0.displayName == name })
    }

    /// Starts `pick` with the server slow to open the stream it asks for, and returns once that
    /// request is waiting on the server.
    private func reloading(
        _ den: FakeJellyfinServer, _ world: AppWorld, _ pick: @escaping @MainActor () async -> Void
    ) async throws -> Task<Void, Never> {
        den.holdResponses(to: .playbackInfo)
        let picking = Task { await pick() }
        try await world.until { den.heldResponseCount == 1 }
        return picking
    }

    @Test("an audio pick and a burn-in pick made during one reload cost one further reload carrying both")
    func picksMadeDuringAReloadMerge() async throws {
        let (den, world, player) = try await openRan(frenchUp: true)
        let english = try audio("English", of: player)
        let german = try audio("German", of: player)
        let picture = try subtitle("English", of: player)
        let switching = try await reloading(den, world) { await player.selectAudioTrack(english) }

        await player.selectAudioTrack(german)
        await player.selectSubtitleTrack(picture)
        den.releaseResponses()
        await switching.value

        let source = "source-\(den.itemID(of: "Ran"))"
        #expect(den.playbackRequests == [
            Request(item: "Ran", startSeconds: nil),
            Request(item: "Ran", startSeconds: 600, audioStreamIndex: 2, subtitleStreamIndex: Self.frenchIndex,
                    mediaSourceID: source),
            Request(item: "Ran", startSeconds: 600, audioStreamIndex: 3, subtitleStreamIndex: Self.pictureIndex,
                    mediaSourceID: source, allowsVideoStreamCopy: false),
        ])
        #expect(player.selectedAudioTrack == german)
        #expect(player.selectedSubtitleTrack == picture)
    }

    @Test("a text subtitle picked during an audio reload is fetched after the last reload and drawn")
    func aTextPickDuringAReloadIsDrawnOnceItLands() async throws {
        let (den, world, player) = try await openRan(frenchUp: false)
        let english = try audio("English", of: player)
        let french = try subtitle("French", of: player)
        let switching = try await reloading(den, world) { await player.selectAudioTrack(english) }

        await player.selectSubtitleTrack(french)
        den.releaseResponses()
        await switching.value

        try await world.until { player.subtitleRenderer != nil }
        #expect(player.selectedSubtitleTrack == french)
        #expect(den.subtitleRequests.map(\.streamIndex) == [Self.frenchIndex])
        #expect(den.subtitleRequests.map(\.afterPlaybackRequests) == [den.playbackRequests.count])
        #expect(den.playbackRequests.last?.subtitleStreamIndex == Self.frenchIndex)
    }

    @Test("a burn-in the server declined yields to the text pick made during it, with no rollback and no retry offer")
    func aDeclinedBurnInYieldsToANewerPick() async throws {
        let (den, world, player) = try await openRan(frenchUp: false, decliningBurnIn: true)
        let picture = try subtitle("English", of: player)
        let french = try subtitle("French", of: player)
        let picking = try await reloading(den, world) { await player.selectSubtitleTrack(picture) }

        await player.selectSubtitleTrack(french)
        den.releaseResponses()
        await picking.value

        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, Self.pictureIndex, Self.frenchIndex])
        #expect(player.selectedSubtitleTrack == french)
        #expect(player.trackSwitchFailure == nil)
    }

    @Test("when going back from a declined burn-in also fails, the menu and the screen land on the subtitle from before")
    func aFailedRollbackStillRestoresTheSubtitle() async throws {
        let (den, world, player) = try await openRan(frenchUp: true, decliningBurnIn: true)
        let picture = try subtitle("English", of: player)
        let french = try subtitle("French", of: player)
        let picking = try await reloading(den, world) { await player.selectSubtitleTrack(picture) }

        den.answerHeldResponses()
        try await world.until { den.heldResponseCount == 1 && den.playbackRequests.count == 2 }
        den.failNextPlaybackInfo()
        den.releaseResponses()
        await picking.value

        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, Self.pictureIndex, Self.frenchIndex])
        #expect(player.selectedSubtitleTrack == french)
        try await world.until { player.sidecarSubtitleInfo != nil }
        #expect(player.trackSwitchFailure?.requested == .subtitle(picture))
        #expect(player.trackSwitchFailure?.fallback == .subtitle(french))
    }

    @Test("a declined burn-in offers no retry when the user picked Off while it was going back")
    func offDuringTheRollbackDropsTheRetryOffer() async throws {
        let (den, world, player) = try await openRan(frenchUp: true, decliningBurnIn: true)
        let picture = try subtitle("English", of: player)
        let picking = try await reloading(den, world) { await player.selectSubtitleTrack(picture) }

        den.answerHeldResponses()
        try await world.until { den.heldResponseCount == 1 && den.playbackRequests.count == 2 }
        await player.selectSubtitleTrack(nil)
        den.releaseResponses()
        await picking.value

        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, Self.pictureIndex, Self.frenchIndex, -1])
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.trackSwitchFailure == nil)
    }

    @Test("a text pick replaced by Off during its own reload is never fetched, and nothing is left on screen")
    func offDuringATextReloadFetchesNothing() async throws {
        let (den, world, player) = try await openRan(frenchUp: false)
        await player.selectSubtitleTrack(try subtitle("English", of: player))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        let french = try subtitle("French", of: player)
        let picking = try await reloading(den, world) { await player.selectSubtitleTrack(french) }

        await player.selectSubtitleTrack(nil)
        den.releaseResponses()
        await picking.value

        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, Self.pictureIndex, Self.frenchIndex, -1])
        #expect(den.subtitleRequests.isEmpty)
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.sidecarSubtitleInfo == nil)
    }

    @Test("a seek made during a text subtitle's reload costs no reload of its own, and the subtitle is fetched once after it")
    func aSeekDuringATextReloadRidesIt() async throws {
        let (den, world, player) = try await openRan(frenchUp: false)
        await player.selectSubtitleTrack(try subtitle("English", of: player))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        let french = try subtitle("French", of: player)
        let picking = try await reloading(den, world) { await player.selectSubtitleTrack(french) }

        await player.commitSeek(to: .seconds(4200))
        den.releaseResponses()
        await picking.value

        try await world.until { player.subtitleRenderer != nil }
        #expect(den.playbackRequests.count == 3)
        #expect(world.engine.calls.filter { $0.hasPrefix("seek(") }.last == "seek(4200.0)")
        #expect(den.subtitleRequests.map(\.afterPlaybackRequests) == [3])
    }

    @Test("a reload that fails with another pick waiting puts back the subtitle from before the first pick, on the menu and on screen")
    func aFailedRunRestoresTheSubtitleFromBeforeIt() async throws {
        let (den, world, player) = try await openRan(frenchUp: true)
        let picture = try subtitle("English", of: player)
        let french = try subtitle("French", of: player)
        let picking = try await reloading(den, world) { await player.selectSubtitleTrack(picture) }

        await player.selectSubtitleTrack(nil)
        den.failNextPlaybackInfo()
        den.releaseResponses()
        await picking.value

        #expect(den.playbackRequests.count == 2)
        #expect(player.selectedSubtitleTrack == french)
        try await world.until { player.sidecarSubtitleInfo != nil }
        #expect(player.trackSwitchFailure?.requested == .subtitle(picture))
        #expect(player.trackSwitchFailure?.fallback == .subtitle(french))
    }

    @Test("a text subtitle whose reload has an audio pick waiting behind it is still drawn when both have landed")
    func aSubtitleReloadFollowedByAnAudioPickStillDraws() async throws {
        let (den, world, player) = try await openRan(frenchUp: false)
        await player.selectSubtitleTrack(try subtitle("English", of: player))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        let french = try subtitle("French", of: player)
        let english = try audio("English", of: player)
        let picking = try await reloading(den, world) { await player.selectSubtitleTrack(french) }

        await player.selectAudioTrack(english)
        den.releaseResponses()
        await picking.value

        try await world.until { player.subtitleRenderer != nil }
        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, Self.pictureIndex, Self.frenchIndex, Self.frenchIndex])
        #expect(den.playbackRequests.map(\.audioStreamIndex) == [nil, 1, 1, 2])
        #expect(player.selectedSubtitleTrack == french)
        #expect(player.selectedAudioTrack == english)
        #expect(den.subtitleRequests.map(\.afterPlaybackRequests) == [4])
    }

    @Test("a pick that was waiting behind a failed reload is forgotten, so the next reload carries the subtitle that is showing")
    func aPickBehindAFailedReloadIsForgotten() async throws {
        let (den, world, player) = try await openRan(frenchUp: true)
        let picking = try await reloading(den, world) {
            await player.selectSubtitleTrack(try? self.subtitle("English", of: player))
        }
        await player.selectSubtitleTrack(nil)
        den.failNextPlaybackInfo()
        den.releaseResponses()
        await picking.value
        try await world.until { player.trackSwitchFailure != nil && player.sidecarSubtitleInfo != nil }

        await player.selectAudioTrack(try audio("English", of: player))

        #expect(den.playbackRequests.count == 3)
        #expect(den.playbackRequests.last?.subtitleStreamIndex == Self.frenchIndex)
        #expect(den.playbackRequests.last?.audioStreamIndex == 2)
    }

    @Test("tapping the subtitle that is already showing during a reload spends no reload and leaves it on screen")
    func reTappingTheShownSubtitleDuringAReloadDoesNothing() async throws {
        let (den, world, player) = try await openRan(frenchUp: true)
        let english = try audio("English", of: player)
        let french = try subtitle("French", of: player)
        let switching = try await reloading(den, world) { await player.selectAudioTrack(english) }

        await player.selectSubtitleTrack(french)
        #expect(player.sidecarSubtitleInfo != nil)
        den.releaseResponses()
        await switching.value

        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, Self.frenchIndex])
        #expect(den.playbackRequests.map(\.audioStreamIndex) == [nil, 2])
    }

    @Test("picking Off where the server was left to choose tells the next reload to carry no subtitle")
    func anExplicitOffIsCarriedByTheNextReload() async throws {
        let (den, world, player) = try await openRan(frenchUp: false)
        #expect(player.selectedSubtitleTrack == nil)

        await player.selectSubtitleTrack(nil)
        await player.selectAudioTrack(try audio("English", of: player))

        #expect(den.playbackRequests.count == 2)
        #expect(den.playbackRequests.last?.subtitleStreamIndex == -1)
        #expect(den.playbackRequests.last?.audioStreamIndex == 2)
        #expect(world.engine.loadedAssets.count == 2)
    }

    @Test("a subtitle pick cut off by moving to the next episode leaves nothing in that episode")
    func aPickCutOffByTheNextEpisodeLeavesNothingBehind() async throws {
        let line = Track(language: "fra", title: "French", .srt(Self.french))
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Shows", of: .shows)
            .series("Severance", in: "Shows", episodes: [2])
            .streams("Severance S1E1", by: .transcode, subtitles: [line])
            .streams("Severance S1E2", by: .transcode, subtitles: [line])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Severance S1E1")), in: try await world.session(on: den))
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .seconds(600), of: .seconds(50 * 60))
        try await world.until { player.nextEpisode?.name == "Severance S1E2" }
        let french = try subtitle("French", of: player)
        let outgoing = world.engine
        outgoing.hold(.subtitleTrack)
        let picking = Task { await player.selectSubtitleTrack(french) }
        try await world.until { () async -> Bool in outgoing.hasParked(.subtitleTrack) }

        await player.playNextEpisode()
        try await world.streamPlays(at: .seconds(1), of: .seconds(50 * 60))
        outgoing.release(.subtitleTrack)
        await picking.value

        #expect(den.playbackRequests.map(\.item) == ["Severance S1E1", "Severance S1E2"])
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.sidecarSubtitleInfo == nil)
        #expect(den.subtitleRequests.isEmpty)
    }
}

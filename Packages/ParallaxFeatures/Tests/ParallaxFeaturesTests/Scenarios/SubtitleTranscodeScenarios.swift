import CoreMedia
import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxSubtitles
import Testing

/// Subtitles while the server re-encodes the stream. The app draws a text subtitle over the
/// picture from a file it fetches, so picking one never restarts the stream. A picture subtitle
/// can only be painted into the video by the server, so picking or leaving one does.
@MainActor
@Suite("Subtitles on a transcode", .timeLimit(.minutes(1)))
struct SubtitleTranscodeScenarios {
    private typealias Request = FakeJellyfinServer.PlaybackRequest

    private static let french = "1\n00:00:01,000 --> 00:00:04,000\nLe château brûle.\n"
    private static let german = "1\n00:00:01,000 --> 00:00:04,000\nDie Burg steht in Flammen.\n"
    private static let frenchIndex = 3
    private static let germanIndex = 4
    private static let pictureIndex = 5

    /// Ran by transcode, ten minutes in: Japanese and English audio, French and German text
    /// subtitles, and an English picture subtitle the server marks as its default.
    private func openRan(
        _ prepare: (FakeJellyfinServer) -> Void = { _ in }
    ) async throws -> (FakeJellyfinServer, AppWorld, PlayerViewModel) {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Ran", in: "Films", minutes: 162)
            .streams("Ran", by: .transcode, audio: [
                FakeJellyfinServer.AudioTrack(language: "jpn", title: "Japanese"),
                FakeJellyfinServer.AudioTrack(language: "eng", title: "English"),
            ], subtitles: [
                FakeJellyfinServer.SubtitleTrack(language: "fra", title: "French", .srt(Self.french)),
                FakeJellyfinServer.SubtitleTrack(language: "deu", title: "German", .srt(Self.german)),
                FakeJellyfinServer.SubtitleTrack(
                    language: "eng", title: "English", .image, isEmbedded: true, isServerDefault: true),
            ])
        prepare(den)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Ran")), in: try await world.session(on: den))
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        return (den, world, player)
    }

    private func row(_ name: String, of player: PlayerViewModel) throws -> SubtitleTrack {
        try #require(player.availableSubtitleTracks.first { $0.displayName == name })
    }

    private func source(of den: FakeJellyfinServer) -> String { "source-\(den.itemID(of: "Ran"))" }

    private func show(_ name: String, on player: PlayerViewModel, in world: AppWorld, bytes: Int) async throws {
        await player.selectSubtitleTrack(try row(name, of: player))
        try await world.until { player.sidecarSubtitleInfo?.byteCount == bytes && player.subtitleRenderer != nil }
    }

    @Test("a picture subtitle is offered burned in, named for its format, and is not picked for the user even as the server's default")
    func pictureSubtitleIsAnOptInBurnIn() async throws {
        let (den, _, player) = try await openRan()

        let picture = try row("English", of: player)
        #expect(picture.isBurnedIn)
        #expect(picture.detailLabel == "PGS")
        #expect(player.availableSubtitleTracks.map(\.isBurnedIn) == [false, false, true])
        #expect(player.selectedSubtitleTrack == nil)
        #expect(den.subtitleRequests.isEmpty)
    }

    @Test("picking a burned-in subtitle reloads the stream with it where it was, and fetches no subtitle file")
    func pickingABurnInReloads() async throws {
        let (den, world, player) = try await openRan()
        let picture = try row("English", of: player)

        await player.selectSubtitleTrack(picture)

        #expect(den.playbackRequests.last == Request(
            item: "Ran", startSeconds: 600, audioStreamIndex: 1, subtitleStreamIndex: Self.pictureIndex,
            mediaSourceID: source(of: den), allowsVideoStreamCopy: false))
        #expect(world.engine.loadedAssets.count == 2)
        #expect(world.engine.loadedAssets.last?.startTime == .seconds(600))
        #expect(player.selectedSubtitleTrack == picture)
        #expect(player.subtitleRenderer == nil)
        #expect(den.subtitleRequests.isEmpty)
    }

    @Test("a reload names the media source it opened with, and only a burned-in subtitle stops the server passing the video through")
    func reloadsCarryTheSourceAndTheCopyIntent() async throws {
        let (den, world, player) = try await openRan()

        await player.selectAudioTrack(try #require(player.availableAudioTracks.last))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        await player.selectSubtitleTrack(try row("English", of: player))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        await player.selectAudioTrack(try #require(player.availableAudioTracks.first))

        #expect(den.playbackRequests == [
            Request(item: "Ran", startSeconds: nil),
            Request(item: "Ran", startSeconds: 600, audioStreamIndex: 2, mediaSourceID: source(of: den)),
            Request(item: "Ran", startSeconds: 600, audioStreamIndex: 2, subtitleStreamIndex: Self.pictureIndex,
                    mediaSourceID: source(of: den), allowsVideoStreamCopy: false),
            Request(item: "Ran", startSeconds: 600, audioStreamIndex: 1, subtitleStreamIndex: Self.pictureIndex,
                    mediaSourceID: source(of: den), allowsVideoStreamCopy: false),
        ])
    }

    @Test("a burn-in the server won't encode puts the previous subtitle back on screen and offers the pick again")
    func declinedBurnInRollsBack() async throws {
        let (den, world, player) = try await openRan { _ = $0.declineBurnIn(of: "Ran") }
        try await show("French", on: player, in: world, bytes: Self.french.utf8.count)
        let french = try row("French", of: player)
        let picture = try row("English", of: player)

        await player.selectSubtitleTrack(picture)

        try await world.until { player.trackSwitchFailure != nil && player.subtitleRenderer != nil }
        #expect(player.selectedSubtitleTrack == french)
        #expect(player.sidecarSubtitleInfo?.byteCount == Self.french.utf8.count)
        #expect(player.trackSwitchFailure?.requested == .subtitle(picture))
        #expect(player.trackSwitchFailure?.fallback == .subtitle(french))
        #expect(den.subtitleRequests.map(\.streamIndex) == [Self.frenchIndex])
    }

    @Test("a burn-in reload the server fails puts the previous subtitle back without fetching it again")
    func failedBurnInRestoresThePreviousSubtitle() async throws {
        let (den, world, player) = try await openRan()
        try await show("French", on: player, in: world, bytes: Self.french.utf8.count)
        let french = try row("French", of: player)
        let picture = try row("English", of: player)
        den.failNextPlaybackInfo()

        await player.selectSubtitleTrack(picture)

        try await world.until { player.trackSwitchFailure != nil && player.subtitleRenderer != nil }
        #expect(player.selectedSubtitleTrack == french)
        #expect(player.trackSwitchFailure?.requested == .subtitle(picture))
        #expect(player.trackSwitchFailure?.fallback == .subtitle(french))
        #expect(den.subtitleRequests.map(\.streamIndex) == [Self.frenchIndex])
        #expect(world.engine.loadedAssets.count == 1)
    }

    @Test("turning a burned-in subtitle off reloads the stream asking for no subtitle, not for the server's default")
    func leavingABurnInForOffReloads() async throws {
        let (den, world, player) = try await openRan()
        await player.selectSubtitleTrack(try row("English", of: player))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))

        await player.selectSubtitleTrack(nil)

        #expect(den.playbackRequests.last == Request(
            item: "Ran", startSeconds: 600, audioStreamIndex: 1, subtitleStreamIndex: -1,
            mediaSourceID: source(of: den)))
        #expect(world.engine.loadedAssets.count == 3)
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.subtitleRenderer == nil)
    }

    @Test("leaving a burned-in subtitle for a text one reloads the stream, then fetches the text once")
    func leavingABurnInForTextReloadsThenFetches() async throws {
        let (den, world, player) = try await openRan()
        await player.selectSubtitleTrack(try row("English", of: player))
        try await world.streamPlays(at: .seconds(600), of: .seconds(162 * 60))
        let french = try row("French", of: player)

        await player.selectSubtitleTrack(french)

        try await world.until { player.subtitleRenderer != nil }
        #expect(den.playbackRequests.last == Request(
            item: "Ran", startSeconds: 600, audioStreamIndex: 1, subtitleStreamIndex: Self.frenchIndex,
            mediaSourceID: source(of: den)))
        #expect(world.engine.loadedAssets.count == 3)
        #expect(player.selectedSubtitleTrack == french)
        #expect(den.subtitleRequests.map(\.streamIndex) == [Self.frenchIndex])
        #expect(den.subtitleRequests.map(\.afterPlaybackRequests) == [3])
    }

    @Test("picking a text subtitle draws it over the stream that is playing, and Off takes it down the same way")
    func textSubtitleCostsNoReload() async throws {
        let (den, world, player) = try await openRan()
        let french = try row("French", of: player)

        await player.selectSubtitleTrack(french)

        try await world.until { player.subtitleRenderer != nil }
        #expect(player.selectedSubtitleTrack == french)
        #expect(player.sidecarSubtitleInfo == SidecarSubtitleInfo(format: .srt, byteCount: Self.french.utf8.count))
        #expect(den.subtitleRequests.map(\.streamIndex) == [Self.frenchIndex])

        await player.selectSubtitleTrack(nil)

        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.subtitleRenderer == nil)
        #expect(den.playbackRequests.count == 1)
        #expect(world.engine.loadedAssets.count == 1)
    }

    @Test("picking another text subtitle takes the old lines down at once and shows it loading until it arrives")
    func aNewPickClearsTheOldLinesWhileItLoads() async throws {
        let (den, world, player) = try await openRan()
        try await show("French", on: player, in: world, bytes: Self.french.utf8.count)
        let german = try row("German", of: player)
        den.holdResponses(to: .subtitles)

        await player.selectSubtitleTrack(german)
        try await world.until { den.heldResponseCount == 1 }

        #expect(player.selectedSubtitleTrack == german)
        #expect(player.subtitleRenderer == nil)
        #expect(player.sidecarSubtitleInfo == nil)
        #expect(player.loadingSubtitleTrackID == german.id)

        den.releaseResponses()

        try await world.until { player.sidecarSubtitleInfo?.byteCount == Self.german.utf8.count }
        #expect(player.subtitleRenderer != nil)
        #expect(player.loadingSubtitleTrackID == nil)
    }

    @Test("a subtitle that has to be fetched shows as loading the moment it is tapped; Off, a burn-in and one already fetched do not")
    func onlyAFetchShowsAsLoading() async throws {
        let (_, world, player) = try await openRan()
        let french = try row("French", of: player)

        player.armSubtitleFetchIndicator(for: french)
        #expect(player.loadingSubtitleTrackID == french.id)

        try await show("French", on: player, in: world, bytes: Self.french.utf8.count)
        #expect(player.loadingSubtitleTrackID == nil)
        await player.selectSubtitleTrack(nil)

        player.armSubtitleFetchIndicator(for: french)
        #expect(player.loadingSubtitleTrackID == nil)
        player.armSubtitleFetchIndicator(for: nil)
        #expect(player.loadingSubtitleTrackID == nil)
        player.armSubtitleFetchIndicator(for: try row("English", of: player))
        #expect(player.loadingSubtitleTrackID == nil)
    }

    @Test("a text subtitle stays picked through an audio switch, and the reload tells the server which one")
    func aTextSubtitleSurvivesAnAudioSwitch() async throws {
        let (den, world, player) = try await openRan()
        try await show("French", on: player, in: world, bytes: Self.french.utf8.count)
        let french = try row("French", of: player)

        await player.selectAudioTrack(try #require(player.availableAudioTracks.last))

        #expect(den.playbackRequests.last == Request(
            item: "Ran", startSeconds: 600, audioStreamIndex: 2, subtitleStreamIndex: Self.frenchIndex,
            mediaSourceID: source(of: den)))
        #expect(player.selectedSubtitleTrack == french)
    }

    @Test("seeking a transcode moves within the stream that is playing, with or without a text subtitle up")
    func seekingStaysInTheStream() async throws {
        let (den, world, player) = try await openRan()

        await player.commitSeek(to: .seconds(3000))
        try await show("French", on: player, in: world, bytes: Self.french.utf8.count)
        await player.commitSeek(to: .seconds(5000))

        #expect(world.engine.calls.filter { $0.hasPrefix("seek(") } == ["seek(3000.0)", "seek(5000.0)"])
        #expect(den.playbackRequests.count == 1)
        #expect(world.engine.loadedAssets.count == 1)
        #expect(den.subtitleRequests.map(\.streamIndex) == [Self.frenchIndex])
    }
}

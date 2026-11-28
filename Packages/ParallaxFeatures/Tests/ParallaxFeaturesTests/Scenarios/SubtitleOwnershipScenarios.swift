import CoreMedia
import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import Testing

/// Who draws a Jellyfin subtitle when the file itself is played. The app draws a text stream
/// from the file the server hands over. Only the engine can draw a picture stream without a
/// re-encode, and only when its own track can be told apart from the others.
@MainActor
@Suite("Subtitles on direct play", .timeLimit(.minutes(1)))
struct SubtitleOwnershipScenarios {
    private typealias Track = FakeJellyfinServer.SubtitleTrack

    private static let line = "1\n00:00:01,000 --> 00:00:04,000\nThe heat is on.\n"
    private static let englishText = Track(language: "eng", title: "English", .srt(line), isEmbedded: true)
    private static let englishPicture = Track(language: "eng", title: "English", .image, isEmbedded: true)
    private static let japanesePicture = Track(language: "jpn", title: "Japanese", .image, isEmbedded: true)

    /// Heat, played as the file. The engine finds one subtitle of its own for each stream in
    /// the file, named for the stream's format, and may come up with one already picked.
    private func openHeat(
        _ subtitles: [Track], remembering language: String? = nil, enginePicks picked: Int? = nil
    ) async throws -> (FakeJellyfinServer, AppWorld, PlayerViewModel) {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", minutes: 170)
            .streams("Heat", subtitles: subtitles)
        if let language { den.subtitleLanguage(language, for: "ana") }
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        let player = try await world.openPlayer()
        let found = TrackInventory.avKitSubtitles(subtitles.filter(\.isEmbedded).map { track in
            let isPicture = if case .image = track.content { true } else { false }
            return LegibleRendition(displayName: isPicture ? "PGS" : "SubRip", languageCode: track.language)
        })
        try await world.streamIsReady(duration: .seconds(170 * 60), tracks: TrackInventory(
            audio: [], subtitles: found.subtitles, selectedSubtitleID: picked.map { .avKitOption($0) }))
        try await world.streamPlays(at: .seconds(1), of: .seconds(170 * 60))
        return (den, world, player)
    }

    private func row(_ name: String, of player: PlayerViewModel) throws -> SubtitleTrack {
        try #require(player.availableSubtitleTracks.first { $0.displayName == name })
    }

    @Test("a file the server lists no subtitles for shows the ones the engine finds in it")
    func engineSubtitlesAreListed() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films", minutes: 170)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        let player = try await world.openPlayer()
        #expect(player.availableSubtitleTracks.isEmpty)

        try await world.streamIsReady(
            duration: .seconds(170 * 60),
            tracks: .avKitSubtitles([LegibleRendition(displayName: "English SDH", languageCode: "eng")]))

        #expect(player.availableSubtitleTracks.map(\.displayName) == ["English SDH"])
        #expect(player.selectedSubtitleTrack == nil)
    }

    @Test("a picture subtitle the engine can draw is listed under the server's name, and picking it costs no new stream")
    func pictureSubtitleIsDrawnByTheEngine() async throws {
        let (den, world, player) = try await openHeat([Self.englishPicture])
        #expect(player.availableSubtitleTracks.map(\.displayName) == ["English"])
        let english = try row("English", of: player)
        #expect(!english.isBurnedIn)
        #expect(world.engine.loadedAssets.first?.engineSubtitlesDisabled == false)

        await player.selectSubtitleTrack(english)

        #expect(world.engine.selectedSubtitleTrackID == .avKitOption(0))
        #expect(player.selectedSubtitleTrack == english)
        #expect(player.subtitleRenderer == nil)
        #expect(den.playbackRequests.count == 1)

        await player.selectSubtitleTrack(nil)

        #expect(world.engine.selectedSubtitleTrackID == nil)
        #expect(player.selectedSubtitleTrack == nil)
    }

    @Test("a file with only text subtitles lists them as rows the app draws, and the engine's subtitles are turned off")
    func textOnlyFileTurnsTheEngineSubtitlesOff() async throws {
        let (den, world, player) = try await openHeat([Self.englishText])
        #expect(world.engine.loadedAssets.first?.engineSubtitlesDisabled == true)
        #expect(player.availableSubtitleTracks.map(\.displayName) == ["English"])
        let english = try row("English", of: player)
        #expect(!english.isBurnedIn)

        await player.selectSubtitleTrack(english)

        try await world.until { player.sidecarSubtitleInfo?.byteCount == Self.line.utf8.count }
        #expect(world.engine.selectedSubtitleTrackID == nil)
        #expect(den.playbackRequests.count == 1)
    }

    @Test("with a text and a picture subtitle in one file, the app draws the text one and the engine draws the picture one")
    func eachStreamGoesToWhoCanDrawIt() async throws {
        let (den, world, player) = try await openHeat([Self.englishText, Self.japanesePicture])
        #expect(world.engine.loadedAssets.first?.engineSubtitlesDisabled == false)
        #expect(player.availableSubtitleTracks.map(\.displayName) == ["English", "Japanese"])
        #expect(player.availableSubtitleTracks.allSatisfy { !$0.isBurnedIn })

        await player.selectSubtitleTrack(try row("English", of: player))

        try await world.until { player.sidecarSubtitleInfo?.format == .srt }
        #expect(world.engine.selectedSubtitleTrackID == nil)

        await player.selectSubtitleTrack(try row("Japanese", of: player))

        #expect(world.engine.selectedSubtitleTrackID == .avKitOption(1))
        #expect(player.subtitleRenderer == nil)
        #expect(den.playbackRequests.count == 1)
    }

    /// Two streams in one language can't be told apart from the engine's side, so the picture
    /// one is not handed the text one's engine track under its name.
    @Test("a picture subtitle that shares its language with another stream is offered burned in, and picking it asks the server for a new stream")
    func ambiguousPictureSubtitleIsBurnedIn() async throws {
        let (den, world, player) = try await openHeat([Self.englishText, Self.englishPicture])
        let picture = try #require(player.availableSubtitleTracks.last)
        #expect(picture.isBurnedIn)
        #expect(player.availableSubtitleTracks.first?.isBurnedIn == false)

        await player.selectSubtitleTrack(picture)

        #expect(den.playbackRequests.map(\.subtitleStreamIndex) == [nil, 3])
        #expect(den.subtitleRequests.isEmpty)
        #expect(player.subtitleRenderer == nil)
        _ = world
    }

    @Test("the subtitle the engine came up with is checked when the engine draws it")
    func enginePickIsCheckedWhenTheEngineDrawsIt() async throws {
        let (_, world, player) = try await openHeat([Self.englishPicture], enginePicks: 0)

        #expect(player.selectedSubtitleTrack?.displayName == "English")
        #expect(!world.engine.calls.contains { $0.hasPrefix("setSubtitleTrack") })
    }

    /// The engine's subtitles stay on for the picture stream, so its own pick of the text
    /// stream would draw a second copy under the app's.
    @Test("the engine coming up with a subtitle the app draws has it turned off, and nothing is checked")
    func enginePickOfATextStreamIsTurnedOff() async throws {
        let (_, world, player) = try await openHeat([Self.englishText, Self.japanesePicture], enginePicks: 0)

        #expect(player.selectedSubtitleTrack == nil)
        #expect(world.engine.calls.contains("setSubtitleTrack(nil)"))
        #expect(player.subtitleRenderer == nil)
    }

    @Test("my remembered subtitle language is drawn by the app, and the engine's own pick of it is turned off")
    func rememberedLanguageIsDrawnByTheApp() async throws {
        let (_, world, player) = try await openHeat([Self.englishText, Self.japanesePicture], remembering: "eng", enginePicks: 0)

        try await world.until { player.sidecarSubtitleInfo?.byteCount == Self.line.utf8.count }
        #expect(player.selectedSubtitleTrack?.displayName == "English")
        #expect(world.engine.calls.contains("setSubtitleTrack(nil)"))
        #expect(world.engine.selectedSubtitleTrackID == nil)
    }

    @Test("a picture subtitle the server names as the default is picked on the engine")
    func serverDefaultPictureSubtitleIsPicked() async throws {
        let picture = Track(language: "eng", title: "English", .image, isEmbedded: true, isServerDefault: true)
        let (_, world, player) = try await openHeat([picture])

        #expect(player.selectedSubtitleTrack?.displayName == "English")
        #expect(world.engine.selectedSubtitleTrackID == .avKitOption(0))
    }

    @Test("a server default that only a burn-in could show is left off")
    func burnInIsNeverPickedByDefault() async throws {
        let picture = Track(language: "eng", title: "English", .image, isEmbedded: true, isServerDefault: true)
        let (den, _, player) = try await openHeat([Self.englishText, picture])

        #expect(try #require(player.availableSubtitleTracks.last).isBurnedIn)
        #expect(player.selectedSubtitleTrack == nil)
        #expect(den.playbackRequests.count == 1)
    }
}

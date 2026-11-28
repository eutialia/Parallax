import CoreMedia
import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxSubtitles
import Testing

/// Subtitles for a film played off an SMB share. The app draws a subtitle file that sits beside
/// the film and is named for it. A subtitle inside the film is the engine's to draw.
@MainActor
@Suite("Subtitles on an SMB film", .timeLimit(.minutes(1)))
struct SubtitleSMBScenarios {
    private static let line = Data("1\n00:00:01,000 --> 00:00:04,000\nThe heat is on.\n".utf8)

    private func openHeat(beside siblings: [String: Data]) async throws -> (AppWorld, PlayerViewModel) {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        try await world.playSMBFilm(beside: siblings)
        let player = try await world.openPlayer()
        return (world, player)
    }

    @Test("an SMB film's subtitle menu lists each subtitle file named for it, by its language")
    func subtitleFilesAreListedByLanguage() async throws {
        let (_, player) = try await openHeat(beside: ["Heat.en.srt": Self.line, "Heat.ja.srt": Self.line])

        let english = try #require(TrackDisplay.languageName("en"))
        let japanese = try #require(TrackDisplay.languageName("ja"))
        #expect(player.availableSubtitleTracks.map(\.displayName) == [english, japanese])
        #expect(player.availableSubtitleTracks.map(\.languageCode) == ["en", "ja"])
        #expect(player.availableSubtitleTracks.allSatisfy { $0.isExternal && !$0.isBurnedIn })
        #expect(player.selectedSubtitleTrack == nil)
    }

    @Test("an SMB film's subtitle menu lists SRT, ASS and WebVTT files and leaves VobSub out")
    func onlyDrawableFilesAreListed() async throws {
        let (_, player) = try await openHeat(beside: [
            "Heat.en.srt": Self.line, "Heat.fr.ass": Self.line, "Heat.de.vtt": Self.line,
            "Heat.ja.idx": Self.line, "Heat.ja.sub": Self.line,
        ])

        #expect(Set(player.availableSubtitleTracks.map(\.languageCode)) == ["en", "fr", "de"])
    }

    @Test("an SMB film's subtitle menu lists no file that isn't named for it")
    func unrelatedFilesAreNotListed() async throws {
        let (_, player) = try await openHeat(beside: [
            "Heat.en.srt": Self.line, "Ran.mp4": AppWorld.mp4Bytes, "Ran.ja.srt": Self.line,
            "Other.srt": Self.line, "readme.txt": Self.line,
        ])

        #expect(player.availableSubtitleTracks.map(\.languageCode) == ["en"])
    }

    @Test("picking an SMB subtitle file reads that file off the share and draws it")
    func pickingASubtitleFileDrawsIt() async throws {
        let (world, player) = try await openHeat(beside: ["Heat.en.srt": Self.line])
        try await world.streamPlays(at: .seconds(1), of: .seconds(170 * 60))
        let english = try #require(player.availableSubtitleTracks.first)

        await player.selectSubtitleTrack(english)

        try await world.until { player.subtitleRenderer != nil }
        #expect(player.selectedSubtitleTrack == english)
        #expect(player.sidecarSubtitleInfo == SidecarSubtitleInfo(format: .srt, byteCount: Self.line.count))
        #expect(player.loadingSubtitleTrackID == nil)
    }

    @Test("an SMB film with no subtitle files lists the engine's subtitles, and the engine draws the one picked")
    func theFilmsOwnSubtitleIsDrawnByTheEngine() async throws {
        let (world, player) = try await openHeat(beside: [:])
        #expect(player.availableSubtitleTracks.isEmpty)

        try await world.streamIsReady(
            duration: .seconds(170 * 60),
            tracks: .avKitSubtitles([LegibleRendition(displayName: "English", languageCode: "eng")]))
        try await world.streamPlays(at: .seconds(1), of: .seconds(170 * 60))

        #expect(player.availableSubtitleTracks.map(\.displayName) == ["English"])
        #expect(world.engine.loadedAssets.first?.engineSubtitlesDisabled == false)
        let english = try #require(player.availableSubtitleTracks.first)

        await player.selectSubtitleTrack(english)

        #expect(world.engine.selectedSubtitleTrackID == english.id)
        #expect(player.selectedSubtitleTrack == english)
        #expect(player.subtitleRenderer == nil)
    }

    @Test("an SMB film whose folder can't be listed for subtitles still plays, with no subtitle files")
    func aFailedSubtitleListingStillPlays() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        let entries = ["Heat.mp4", "Heat.en.srt"].map {
            SMBDirectoryEntry(name: $0, isDirectory: false, size: 1, modifiedAt: nil)
        }
        world.nas.setListingScript([.entries(entries)])
        world.nas.setContents(AppWorld.mp4Bytes)
        let folder = await world.openSMBFolder(AppWorld.smbRef, share: "Media")
        try await world.until { !folder.isLoading }
        world.nas.setListingOutcome(.fails(POSIXError(.ETIMEDOUT)))
        folder.play(try #require(folder.media.first))

        let player = try await world.openPlayer()

        #expect(player.availableSubtitleTracks.isEmpty)
        #expect(world.engine.loadedAssets.count == 1)
    }
}

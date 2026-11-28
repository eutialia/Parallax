import CoreGraphics
import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxSubtitles
import Testing

/// Subtitles stored inside a film played off an SMB share. The film is a real Matroska file
/// with an ASS stream titled "ASS", flagged for the hard of hearing, and an SRT stream titled
/// "SRT", flagged as forced: a line of each at 1 s, 5 s and 9 s, two seconds long. The app reads the lines out of the file as the engine fetches
/// its pictures, and draws them itself.
@MainActor
@Suite("Subtitles stored in an SMB film", .timeLimit(.minutes(1)))
struct SubtitleFileScenarios {
    private static let beside = Data("1\n00:00:03,000 --> 00:00:04,500\nFrom the file beside it.\n".utf8)

    private static var film: Data {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "Fixtures/text-subtitles-short", withExtension: "mkv"))
            return try Data(contentsOf: url)
        }
    }

    /// The film with the text of every SRT line replaced by bytes that are no text in any
    /// encoding the app reads.
    private static var filmWithUnreadableSRT: Data {
        get throws {
            var film = try film
            let text = Data("SRT line".utf8)
            var from = film.startIndex
            while let found = film.range(of: text, in: from..<film.endIndex) {
                film.replaceSubrange(found, with: Data(repeating: 0xFF, count: text.count))
                from = found.upperBound
            }
            return film
        }
    }

    private func openHeat(
        _ film: Data? = nil, beside siblings: [String: Data] = [:]
    ) async throws -> (AppWorld, PlayerViewModel) {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        try await world.playSMBFilm(named: "Heat.mkv", contents: try film ?? Self.film, beside: siblings)
        let player = try await world.openPlayer()
        try await world.streamPlays(at: .zero, of: .seconds(10))
        return (world, player)
    }

    /// Whether the app's own subtitle drawing shows anything at `seconds`.
    private static func draws(_ player: PlayerViewModel, at seconds: Double) async -> Bool {
        guard let renderer = player.subtitleRenderer else { return false }
        let size = CGSize(width: 640, height: 360)
        await renderer.setCanvas(size: size, scale: 1, storageSize: size)
        return await renderer.frame(at: seconds)?.image != nil
    }

    @Test("an SMB film's own ASS and SRT subtitles are on the menu by the names and flags the file gives them, ahead of the files beside it, and none is on")
    func theFilmsSubtitlesAreListed() async throws {
        let (_, player) = try await openHeat(beside: ["Heat.en.srt": Self.beside])

        let english = try #require(TrackDisplay.languageName("en"))
        #expect(player.availableSubtitleTracks.map(\.displayName) == ["ASS", "SRT", english])
        #expect(player.availableSubtitleTracks.map(\.detailLabel) == ["ASS · Embedded", "SRT · Embedded", "SRT · External"])
        #expect(player.availableSubtitleTracks.map(\.isExternal) == [false, false, true])
        #expect(player.availableSubtitleTracks.map(\.isSDH) == [true, false, false])
        #expect(player.availableSubtitleTracks.map(\.isForced) == [false, true, false])
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.subtitleRenderer == nil)
    }

    @Test("picking one of the film's own subtitles draws each of its lines for its own time, once the engine has fetched the pictures they are stored beside")
    func pickingAStoredSubtitleDrawsItsLines() async throws {
        let (world, player) = try await openHeat()
        let srt = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })

        await player.selectSubtitleTrack(srt)

        #expect(player.selectedSubtitleTrack == srt)
        #expect(player.loadingSubtitleTrackID == nil)

        try await world.engineFetchesTheWholeFilm()
        try await world.until { await Self.draws(player, at: 10) }
        for (seconds, shows) in [(0.5, false), (2.0, true), (3.5, false), (6.0, true), (7.5, false)] {
            #expect(await Self.draws(player, at: seconds) == shows, "at \(seconds) s")
        }
        #expect(player.sidecarSubtitleInfo?.format == .srt)
    }

    @Test("the film's ASS subtitle is drawn as its author wrote it, not in my style")
    func aStoredASSSubtitleKeepsItsLook() async throws {
        let (world, player) = try await openHeat()
        let ass = try #require(player.availableSubtitleTracks.first { $0.displayName == "ASS" })
        try await world.engineFetchesTheWholeFilm()

        await player.selectSubtitleTrack(ass)

        try await world.until { await Self.draws(player, at: 10) }
        #expect(player.sidecarSubtitleInfo?.format == .ass)
        // The author put the line at 9 s in the top left corner.
        let renderer = try #require(player.subtitleRenderer)
        let size = CGSize(width: 640, height: 360)
        await renderer.setCanvas(size: size, scale: 1, storageSize: size)
        let corner = try #require(await renderer.frame(at: 10))
        let bottom = try #require(await renderer.frame(at: 2))
        #expect(corner.imageRect.maxY < 120 && corner.imageRect.minX < 60, "\(corner.imageRect)")
        #expect(bottom.imageRect.minY > 240, "\(bottom.imageRect)")
    }

    @Test("turning the film's own subtitle off stops drawing it, and picking a file beside the film draws that file instead")
    func offAndTheFileBesideReplaceIt() async throws {
        let (world, player) = try await openHeat(beside: ["Heat.en.srt": Self.beside])
        try await world.engineFetchesTheWholeFilm()
        let stored = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })
        let file = try #require(player.availableSubtitleTracks.first { $0.isExternal })
        await player.selectSubtitleTrack(stored)
        try await world.until { await Self.draws(player, at: 2) }

        await player.selectSubtitleTrack(nil)
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.subtitleRenderer == nil)

        await player.selectSubtitleTrack(stored)
        try await world.until { await Self.draws(player, at: 2) }
        await player.selectSubtitleTrack(file)
        try await world.until { await Self.draws(player, at: 3.5) }
        #expect(player.selectedSubtitleTrack == file)
        #expect(!(await Self.draws(player, at: 2)))
    }

    @Test("picking the film's stored subtitle while the engine draws one of its own turns the engine's off, so only one is on screen")
    func theEnginesSubtitleGoesOff() async throws {
        let (world, player) = try await openHeat()
        try await world.streamIsReady(
            duration: .seconds(10),
            tracks: .avKitSubtitles([LegibleRendition(displayName: "Captions", languageCode: "eng")]))
        let captions = try #require(player.availableSubtitleTracks.first { $0.displayName == "Captions" })
        let stored = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })
        await player.selectSubtitleTrack(captions)
        #expect(world.engine.selectedSubtitleTrackID == captions.id)

        await player.selectSubtitleTrack(stored)

        #expect(world.engine.selectedSubtitleTrackID == nil)
        #expect(player.selectedSubtitleTrack == stored)
    }

    @Test("a file beside the film that cannot be read puts the film's own subtitle back on screen")
    func aFailedFileFallsBackToTheStoredSubtitle() async throws {
        let (world, player) = try await openHeat(beside: ["Heat.en.srt": Data()])
        try await world.engineFetchesTheWholeFilm()
        let stored = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })
        let file = try #require(player.availableSubtitleTracks.first { $0.isExternal })
        await player.selectSubtitleTrack(stored)
        try await world.until { await Self.draws(player, at: 2) }
        let failures = player.subtitleFetchFailureTick

        await player.selectSubtitleTrack(file)

        try await world.until { player.subtitleFetchFailureTick != failures }
        #expect(player.selectedSubtitleTrack == stored)
        try await world.until { await Self.draws(player, at: 2) }
    }

    @Test("one of the film's own subtitles whose text cannot be read does not stay picked: the subtitle from before it is back on screen, and the chip is told")
    func anUnreadableStoredSubtitleFallsBack() async throws {
        let (world, player) = try await openHeat(try Self.filmWithUnreadableSRT)
        try await world.engineFetchesTheWholeFilm()
        let ass = try #require(player.availableSubtitleTracks.first { $0.displayName == "ASS" })
        let srt = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })
        await player.selectSubtitleTrack(ass)
        try await world.until { await Self.draws(player, at: 2) }
        let failures = player.subtitleFetchFailureTick

        await player.selectSubtitleTrack(srt)

        try await world.until { player.subtitleFetchFailureTick != failures }
        #expect(player.selectedSubtitleTrack == ass)
        try await world.until { await Self.draws(player, at: 2) }
    }

    @Test("an unreadable subtitle of the film's own, picked with none on, ends at Off")
    func anUnreadableStoredSubtitleEndsAtOff() async throws {
        let (world, player) = try await openHeat(try Self.filmWithUnreadableSRT)
        try await world.engineFetchesTheWholeFilm()
        let srt = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })

        await player.selectSubtitleTrack(srt)

        try await world.until { player.subtitleFetchFailureTick == 1 }
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.subtitleRenderer == nil)
    }

    @Test("after a seek, the picked subtitle draws the lines stored beside the pictures the engine fetches from there, and an earlier line only once the engine fetches its part of the film")
    func aSeekDrawsTheLinesFromThere() async throws {
        let (world, player) = try await openHeat()
        let srt = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })
        await player.selectSubtitleTrack(srt)

        await player.commitSeek(to: .seconds(9))
        try await world.engineFetchesTheFilmsLastPart()

        try await world.until { await Self.draws(player, at: 9.5) }
        #expect(player.selectedSubtitleTrack == srt)
        #expect(!(await Self.draws(player, at: 1.5)))

        try await world.engineFetchesTheWholeFilm()
        try await world.until { await Self.draws(player, at: 1.5) }
        #expect(await Self.draws(player, at: 9.5))
    }

    @Test("after the stream fails and I retry, the film's own subtitles are on the menu again with none on, and a pick draws its lines")
    func retryListsTheFilmsSubtitlesAgain() async throws {
        let (world, player) = try await openHeat()
        let srt = try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" })
        await player.selectSubtitleTrack(srt)
        try await world.engineFetchesTheWholeFilm()
        try await world.until { await Self.draws(player, at: 1.5) }
        world.streamFailsToDecode()
        try await world.until { if case .failed = player.phase { true } else { false } }

        await player.retry()
        try await world.until { world.engines.count == 2 && world.engine.calls.contains("play") }
        try await world.streamPlays(at: .zero, of: .seconds(10))

        #expect(player.availableSubtitleTracks.map(\.displayName) == ["ASS", "SRT"])
        #expect(player.selectedSubtitleTrack == nil)
        #expect(player.subtitleRenderer == nil)
        await player.selectSubtitleTrack(try #require(player.availableSubtitleTracks.first { $0.displayName == "SRT" }))
        try await world.engineFetchesTheWholeFilm()
        try await world.until { await Self.draws(player, at: 1.5) }
    }
}

import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Detail", .timeLimit(.minutes(1)))
struct DetailScenarios {
    @Test("a half-watched movie's page offers Resume at its saved position, and Play from Beginning on its tile starts over")
    func resumeAndPlayFromBeginning() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Arrival", in: "Films", minutes: 116).watch("Arrival", minutes: 30)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        let arrival = ItemID(rawValue: den.itemID(of: "Arrival"))
        let detail = await world.app.movieDetail(arrival, on: session)
        await detail.load()

        #expect(detail.playButtonTitle == "Resume")
        detail.play()
        #expect(world.playRequest == AppWorld.PlayRequest(
            item: arrival.rawValue, server: "Den", fromBeginning: false, resumeMinutes: 30
        ))

        world.app.playback.dismiss()
        await world.clock.waitForSleepers()
        world.clock.advance(by: .seconds(1))
        try await world.until { !world.app.playback.isPlayerPresent }

        try await world.openHome()
        let tile = try #require(world.app.home?.continueWatching.first)
        let menu = MediaTileMenuAction.menu(for: tile.item, on: session, context: MediaTileMenuContext(moviePlaysOnTap: true))
        #expect(menu.contains(.playFromBeginning(arrival)))
        await world.app.perform(.playFromBeginning(arrival), on: session)

        #expect(world.playRequest == AppWorld.PlayRequest(item: arrival.rawValue, server: "Den", fromBeginning: true))
    }

    @Test("finishing a movie from its page and closing the player turns Resume back into Play")
    func movieRefreshesAfterPlayback() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Arrival", in: "Films", minutes: 116).watch("Arrival", minutes: 30)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let detail = await world.app.movieDetail(ItemID(rawValue: den.itemID(of: "Arrival")), on: try await world.session(on: den))
        await detail.load()
        #expect(detail.playButtonTitle == "Resume")
        detail.play()
        try await world.openPlayer()

        den.finish("Arrival")
        await world.closePlayer()

        try await world.until { detail.playButtonTitle == "Play" }
    }

    @Test("finishing an episode from the series page and closing the player moves Resume on to the next one")
    func seriesRefreshesAfterPlayback() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Shows", of: .shows)
            .series("Severance", in: "Shows", episodes: [3]).finish("Severance S1E1")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let detail = await world.app.seriesDetail(ItemID(rawValue: den.itemID(of: "Severance")), on: try await world.session(on: den))
        await detail.load()
        #expect(detail.playAction.title == "Resume S1 E2")
        detail.play()
        try await world.openPlayer()

        den.finish("Severance S1E2")
        await world.closePlayer()

        try await world.until { detail.playAction.title == "Resume S1 E3" }
    }

    @Test("a series with its first episode watched offers to resume at the next one")
    func seriesOffersTheNextEpisode() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Shows", of: .shows)
            .series("Severance", in: "Shows", episodes: [3]).finish("Severance S1E1")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let detail = await world.app.seriesDetail(ItemID(rawValue: den.itemID(of: "Severance")), on: try await world.session(on: den))
        await detail.load()

        #expect(detail.playAction.title == "Resume S1 E2")
        detail.play()

        #expect(world.playRequest == AppWorld.PlayRequest(
            item: den.itemID(of: "Severance S1E2"), server: "Den", fromBeginning: false
        ))
    }

    @Test("marking an episode watched from its shelf moves the series on to the episode after it")
    func markingAnEpisodeWatchedUpdatesTheSeries() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Shows", of: .shows)
            .series("Severance", in: "Shows", episodes: [3]).finish("Severance S1E1")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        let detail = await world.app.seriesDetail(ItemID(rawValue: den.itemID(of: "Severance")), on: session)
        await detail.load()
        guard case .loaded(_, let seasons) = detail.state, let season = seasons.first else {
            Issue.record("the series page never loaded its season")
            return
        }
        let second = try #require(detail.episodes(for: season.id).first { $0.name == "Severance S1E2" })

        let menu = MediaTileMenuAction.menu(for: .episode(second), on: session, context: MediaTileMenuContext(showsGoToSeries: false))
        #expect(menu == [.togglePlayed(second.id, played: false)])
        await world.app.perform(.togglePlayed(second.id, played: false), on: session)

        try await world.until { detail.playAction.title == "Resume S1 E3" }
        #expect(detail.episodes(for: season.id).map(\.userData.played) == [true, true, false])
    }
}

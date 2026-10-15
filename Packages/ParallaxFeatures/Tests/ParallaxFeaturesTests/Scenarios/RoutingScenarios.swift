import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import Testing
import ParallaxTestScaling

/// What a change of sources does to the rest of the app, asserted the moment the change returns:
/// a step the user takes right after must find it already in place.
@MainActor
@Suite("Routing", .scaledTimeLimit())
struct RoutingScenarios {
    @Test("signing out of the last server lands on login with Home and the library list already empty")
    func loginClearsHomeAndLibraries() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films").watch("Heat", minutes: 40)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.openHome()
        #expect(world.continueWatching == ["Heat"])
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()

        await settings.signOut(try #require(settings.sessions.first))

        #expect(world.app.router.destination == .login)
        #expect(world.app.home == nil)
        #expect(world.sidebar.isEmpty)
        #expect(world.app.libraries.isResolving)
        #expect(!world.app.isContentReady)
        #expect(world.app.launchGate.isFinished)
    }

    @Test("adding a first SMB server from login re-arms the launch reveal, and the reveal opens without waiting out its timeout")
    func firstSMBAddRevealsWithoutTheTimeout() async throws {
        let world = try await AppWorld.launch()
        try await world.until { world.app.launchGate.isFinished }
        world.nas.acceptOnly(password: "hunter2")
        world.nas.setShareListOutcome(.shares([SMBShare(name: "Media", comment: "")]))
        let add = world.app.makeSMBAddServer()
        add.host = "nas.local"
        add.username = "ana"
        add.password = "hunter2"
        add.connect()
        try await world.until { add.showShareSelector }
        add.toggleShare("Media")

        #expect(await add.save())

        #expect(world.app.router.destination == .home)
        #expect(!world.app.launchGate.isFinished)
        world.showLaunchStage()
        try await world.openHome()
        #expect(world.app.launchGate.releasedAtRawTime != nil)
        #expect(world.app.isContentReady)
    }

    @Test("playing on the remaining server right after the active one signs out keeps that player open")
    func playRightAfterASwitchStaysOpen() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies").movie("Alien", in: "Movies")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        let atticSession = try await world.session(on: attic)
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()

        await settings.signOut(try #require(settings.sessions.first { $0.serverName == "Den" }))
        world.app.playback.play(ItemID(rawValue: attic.itemID(of: "Alien")), in: atticSession)
        try await world.openHome()

        #expect(world.app.router.activeServerID == ServerID(rawValue: attic.id))
        #expect(world.playRequest == AppWorld.PlayRequest(item: attic.itemID(of: "Alien"), server: "Attic", fromBeginning: false))
    }

    @Test("a video from a server that stays signed in keeps playing when the active server signs out")
    func playerOnALiveServerSurvivesTheSwitch() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies").movie("Alien", in: "Movies", minutes: 117)
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        world.app.playback.play(ItemID(rawValue: attic.itemID(of: "Alien")), in: try await world.session(on: attic))
        try await world.openPlayer()
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()

        await settings.signOut(try #require(settings.sessions.first { $0.serverName == "Den" }))
        try await world.openHome()

        #expect(world.app.router.activeServerID == ServerID(rawValue: attic.id))
        #expect(world.playRequest == AppWorld.PlayRequest(item: attic.itemID(of: "Alien"), server: "Attic", fromBeginning: false))
        #expect(!world.engine.calls.contains("endAudio"))
    }

    @Test("signing out the active server re-closes the launch reveal until the next server's Home and library list settle")
    func switchingServersRearmsTheReveal() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films")
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies").movie("Alien", in: "Movies")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")], launchReveal: .homeAndLibraries)
        try await world.openHome()
        #expect(world.app.isContentReady)
        attic.holdResponses(to: .libraryList)
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()

        await settings.signOut(try #require(settings.sessions.first { $0.serverName == "Den" }))

        #expect(world.app.router.activeServerID == ServerID(rawValue: attic.id))
        #expect(!world.app.isContentReady)
        attic.releaseResponses()
        try await world.openHome()
        #expect(world.app.isContentReady)
    }
}

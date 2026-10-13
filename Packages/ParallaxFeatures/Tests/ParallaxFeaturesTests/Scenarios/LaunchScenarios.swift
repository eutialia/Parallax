import ParallaxFeatures
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Launch", .timeLimit(.minutes(1)))
struct LaunchScenarios {
    @Test("a cold launch with no saved server lands on login and cuts the launch story")
    func coldLaunchWithoutServerLandsOnLogin() async throws {
        let world = try await AppWorld.launch()

        #expect(world.app.router.destination == .login)
        try await world.until { world.app.launchGate.isFinished }
    }

    @Test("a launch with a saved, signed-in Jellyfin server lands on home under the launch story")
    func savedServerLandsOnHome() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])

        #expect(world.app.router.destination == .home)
        #expect(world.app.router.activeServerID == ServerID(rawValue: den.id))
        #expect(!world.app.launchGate.isFinished)
    }

    @Test("a cold launch with a saved server keeps the library list loading, not empty, until the server answers")
    func coldLaunchListLoadsInsteadOfEmpty() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
        den.holdResponses(to: .libraryList)
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        try await world.until { den.heldResponseCount == 1 }

        #expect(world.app.libraries.isResolving)
        #expect(world.sidebar.isEmpty)

        den.releaseResponses()
        try await world.openHome()
        #expect(!world.app.libraries.isResolving)
        #expect(world.sidebar == [AppWorld.SidebarSection(title: "Libraries", libraries: ["Films"])])
    }

    @Test("on Apple TV a relaunch with only the library list cached opens the reveal onto the tabs, not the spinner")
    func tvRevealOnCachedLibrariesShowsTheTabs() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")], launchReveal: .homeAndLibraries)
        try await world.openHome()
        #expect(world.continueWatching.isEmpty)

        den.holdResponses()
        await world.relaunch()
        try await world.until { world.app.launchGate.releasedAtRawTime != nil }

        #expect(world.app.isContentReady)
        #expect(world.sidebar == [AppWorld.SidebarSection(title: "Libraries", libraries: ["Films"])])
        try await world.until { world.app.home?.state == .loading }

        den.releaseResponses()
        try await world.openHome()
    }

    @Test("when content never settles, the launch reveal opens after 15 seconds")
    func revealOpensWhenContentNeverSettles() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.showLaunchStage()
        try await world.clock.waitForSleep(dueIn: .seconds(15))
        #expect(world.clock.pendingSleeps.first == .seconds(15), "something can open the reveal before the watchdog")

        world.clock.advance(by: .seconds(15))
        try await world.until { world.app.launchGate.releasedAtRawTime != nil }
    }

    @Test("closing the app while the launch is still loading does not open the reveal")
    func cancellingTheLaunchDoesNotFireTheWatchdog() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.showLaunchStage()
        try await world.clock.waitForSleep(dueIn: .seconds(15))

        await world.quit()

        #expect(world.clock.pendingSleeps == [], "the watchdog outlived the app")
        #expect(world.app.launchGate.releasedAtRawTime == nil)
    }
}

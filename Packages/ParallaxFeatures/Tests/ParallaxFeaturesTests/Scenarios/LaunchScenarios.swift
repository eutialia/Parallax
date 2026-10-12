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

    @Test("when content never settles, the launch reveal opens after 15 seconds")
    func revealOpensWhenContentNeverSettles() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.showLaunchStage()
        await world.clock.waitForSleepers()

        world.clock.advance(by: .seconds(14))
        #expect(world.app.launchGate.releasedAtRawTime == nil)

        world.clock.advance(by: .seconds(1))
        try await world.until { world.app.launchGate.releasedAtRawTime != nil }
    }

    @Test("closing the app while the launch is still loading does not open the reveal")
    func cancellingTheLaunchDoesNotFireTheWatchdog() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.showLaunchStage()
        await world.clock.waitForSleepers()

        await world.quit()
        world.clock.advance(by: .seconds(15))

        #expect(world.app.launchGate.releasedAtRawTime == nil)
    }
}

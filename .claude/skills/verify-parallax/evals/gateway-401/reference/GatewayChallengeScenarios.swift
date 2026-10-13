import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Server behind a login gateway", .timeLimit(.minutes(1)))
struct GatewayChallengeScenarios {
    @Test("a gateway asking for its own login does not sign the user out, and Home loads once the gateway lets them through")
    func gatewayChallengeKeepsTheSession() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Arrival", in: "Films").watch("Arrival", minutes: 10)
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        try await world.openHome()
        #expect(world.continueWatching == ["Arrival"])

        den.putBehindGateway()
        await world.app.loadLibraries()
        den.clearGateway()

        // Rejections are handled in arrival order, so once Attic's has been, any for Den has too.
        attic.revokeAllTokens()
        await world.app.loadLibraries()
        try await world.until { await world.serverRows().last == AppWorld.ServerRow(name: "Attic", signedIn: false) }

        #expect(world.app.router.destination == .home)
        #expect(await world.serverRows() == [
            AppWorld.ServerRow(name: "Den", signedIn: true),
            AppWorld.ServerRow(name: "Attic", signedIn: false),
        ])
        try await world.until { world.continueWatching == ["Arrival"] }
    }
}

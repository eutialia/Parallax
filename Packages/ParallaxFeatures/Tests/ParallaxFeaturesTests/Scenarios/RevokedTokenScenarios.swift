import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Revoked token", .timeLimit(.minutes(1)))
struct RevokedTokenScenarios {
    @Test("a server that revokes our token is signed out, its row stays as signed-out, and the app returns to login when it was the only server")
    func revokedTokenSignsOutAndReturnsToLogin() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Movies")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        await world.openHome()
        #expect(world.sidebar == [AppWorld.SidebarSection(title: "Libraries", libraries: ["Movies"])])

        den.revokeAllTokens()
        await world.openHome()
        try await world.until { world.app.router.destination == .login }

        #expect(await world.serverRows() == [AppWorld.ServerRow(name: "Den", signedIn: false)])
    }
}

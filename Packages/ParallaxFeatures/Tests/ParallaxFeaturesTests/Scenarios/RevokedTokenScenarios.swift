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

    @Test("signing a revoked server back in survives a late reply to the token it replaced")
    func lateRejectionOfTheReplacedTokenKeepsTheNewSignIn() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let attic = FakeJellyfinServer(name: "Attic").user("bo")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        den.holdResponses(to: .libraryList)
        let staleLoad = Task { await world.app.loadLibraries() }
        try await world.until { den.heldResponseCount == 1 }

        den.revokeAllTokens()
        let signingOut = Task { await world.openHome() }
        try await world.until {
            await world.serverRows() == [
                AppWorld.ServerRow(name: "Den", signedIn: false),
                AppWorld.ServerRow(name: "Attic", signedIn: true),
            ]
        }
        let login = LoginViewModel(app: world.app, prefilledServerURL: den.url.absoluteString)
        login.username = "ana"
        await login.submit()
        den.releaseResponses()
        await staleLoad.value
        await signingOut.value

        // Rejections are handled in arrival order, so once Attic's has been, Den's late one has too.
        attic.revokeAllTokens()
        await world.openHome()
        try await world.until { await world.serverRows().last == AppWorld.ServerRow(name: "Attic", signedIn: false) }
        let rows = await world.serverRows()
        #expect(rows == [
            AppWorld.ServerRow(name: "Den", signedIn: true),
            AppWorld.ServerRow(name: "Attic", signedIn: false),
        ])
    }
}

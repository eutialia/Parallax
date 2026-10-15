import ParallaxFeatures
import ParallaxJellyfinTestSupport
import ParallaxTestScaling
import Testing

@MainActor
@Suite("Minimum server version", .scaledTimeLimit())
struct MinimumServerVersionScenarios {
    nonisolated static let refusal = "Parallax needs Jellyfin 12 or newer. This server runs 11.0.3."

    @Test(
        "adding a server signs in from Jellyfin 12 on, and refuses an older one with the version it runs",
        arguments: [
            ("11.0.3", refusal, AppRouter.Destination.login, [AppWorld.ServerRow]()),
            ("12.0.0", nil, .home, [AppWorld.ServerRow(name: "Den", signedIn: true)]),
        ] as [(String, String?, AppRouter.Destination, [AppWorld.ServerRow])]
    )
    func addingAServer(
        version: String, message: String?, destination: AppRouter.Destination, rows: [AppWorld.ServerRow]
    ) async throws {
        let den = FakeJellyfinServer(name: "Den").version(version).user("ana", password: "hunter2")
        let world = try await AppWorld.launch()
        let login = LoginViewModel(app: world.app)
        login.serverURLInput = den.url.absoluteString
        login.username = "ana"
        login.password = "hunter2"

        await login.submit()

        #expect(login.errorMessage == message)
        #expect(world.app.router.destination == destination)
        #expect(await world.serverRows() == rows)
    }

    @Test("Quick Connect against a Jellyfin 11 server is refused before a code is shown")
    func quickConnectRefusesAnOldServer() async throws {
        let den = FakeJellyfinServer(name: "Den").version("11.0.3").user("ana")
        let world = try await AppWorld.launch()
        let login = LoginViewModel(app: world.app)
        login.serverURLInput = den.url.absoluteString
        login.switchToQuickConnect()
        let quickConnect = login.makeQuickConnectModel()

        await quickConnect.consume(serverURLInput: login.serverURLInput)

        #expect(quickConnect.uiState == .failure(Self.refusal))
        #expect(await world.serverRows() == [])
    }
}

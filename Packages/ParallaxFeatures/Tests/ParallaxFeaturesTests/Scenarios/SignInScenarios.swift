import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Sign in", .timeLimit(.minutes(1)))
struct SignInScenarios {
    @Test("signing in from login moves to home and replays the launch reveal over its first boot")
    func signingInMovesLoginToHome() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana", password: "hunter2")
        let world = try await AppWorld.launch()
        try await world.until { world.app.launchGate.isFinished }

        try await world.app.signIn(server: den.url, username: "ana", password: "hunter2")

        #expect(world.app.router.destination == .home)
        try await world.until { !world.app.launchGate.isFinished }
        #expect(await world.serverRows() == [AppWorld.ServerRow(name: "Den", signedIn: true)])
    }

    @Test("signing in with a wrong password shows the server's error, stays on login and saves nothing")
    func wrongPasswordStaysOnLogin() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana", password: "hunter2")
        let world = try await AppWorld.launch()
        let login = LoginViewModel(app: world.app)
        login.serverURLInput = den.url.absoluteString
        login.username = "ana"
        login.password = "hunter3"

        await login.submit()

        #expect(login.errorMessage == "Incorrect username or password.")
        #expect(world.app.router.destination == .login)
        #expect(await world.serverRows() == [])
    }

    @Test("a server address typed without a scheme is normalized, and sign-in succeeds against it")
    func addressWithoutSchemeSignsIn() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana", password: "hunter2")
        let world = try await AppWorld.launch()
        let login = LoginViewModel(app: world.app)
        login.serverURLInput = " \(try #require(den.url.host())) "
        login.username = "ana"
        login.password = "hunter2"

        await login.submit()

        #expect(login.errorMessage == nil)
        #expect(world.app.router.destination == .home)
        #expect(await world.serverRows() == [AppWorld.ServerRow(name: "Den", signedIn: true)])
    }

    @Test("Quick Connect shows a code, and once the server approves it the app lands on home with the server saved")
    func quickConnectApproval() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch()
        let login = LoginViewModel(app: world.app)
        login.serverURLInput = den.url.absoluteString
        login.switchToQuickConnect()
        let quickConnect = login.makeQuickConnectModel()

        let pairing = Task { await quickConnect.consume(serverURLInput: login.serverURLInput) }
        try await world.until { quickConnect.uiState == .showingCode("100001") }
        #expect(world.app.router.destination == .login)

        await world.clock.waitForSleepers()
        den.approveQuickConnect(code: "100001", as: "ana")
        world.clock.advance(by: .seconds(5))
        await pairing.value

        #expect(world.app.router.destination == .home)
        #expect(await world.serverRows() == [AppWorld.ServerRow(name: "Den", signedIn: true)])
    }

    @Test("a server found on the LAN pre-fills the login address")
    func discoveredServerPrefillsAddress() async throws {
        let den = FakeJellyfinServer(name: "Den")
        let world = try await AppWorld.launch(discovering: [den])
        let login = LoginViewModel(app: world.app)

        let discovery = Task { await login.discoverServers() }
        try await world.until { login.serverURLInput == den.url.absoluteString }
        discovery.cancel()

        #expect(login.discoveredServers.map(\.name) == ["Den"])
    }

    @Test("a server that comes up while the app is away is listed on login once the user is back")
    func returningToLoginRescansTheLAN() async throws {
        let den = FakeJellyfinServer(name: "Den")
        let attic = FakeJellyfinServer(name: "Attic")
        let world = try await AppWorld.launch(discovering: [den])
        let login = LoginViewModel(app: world.app)
        let discovery = Task { await login.discoverServers() }
        try await world.until { login.discoveredServers.map(\.name) == ["Den"] }

        world.background()
        try world.lanServerComesUp(attic)
        world.foreground()

        try await world.until { login.discoveredServers.map(\.name) == ["Den", "Attic"] }
        discovery.cancel()
    }

    /// The Local Network prompt is a system alert: answering it deactivates the scene and activates
    /// it again without ever backgrounding the app. That return has to rescan too.
    @Test("answering the Local Network prompt rescans the LAN, though the app never left the foreground")
    func activationWithoutBackgroundRescansTheLAN() async throws {
        let den = FakeJellyfinServer(name: "Den")
        let attic = FakeJellyfinServer(name: "Attic")
        let world = try await AppWorld.launch(discovering: [den])
        let login = LoginViewModel(app: world.app)
        let discovery = Task { await login.discoverServers() }
        try await world.until { login.discoveredServers.map(\.name) == ["Den"] }

        try world.lanServerComesUp(attic)
        world.foreground()

        try await world.until { login.discoveredServers.map(\.name) == ["Den", "Attic"] }
        discovery.cancel()
    }

    @Test("re-authenticating a known server keeps its address even when another server is on the LAN")
    func prefilledAddressBeatsDiscovery() async throws {
        let den = FakeJellyfinServer(name: "Den")
        let attic = FakeJellyfinServer(name: "Attic")
        let world = try await AppWorld.launch(discovering: [attic])
        let login = LoginViewModel(app: world.app, prefilledServerURL: den.url.absoluteString)

        let discovery = Task { await login.discoverServers() }
        try await world.until { !login.discoveredServers.isEmpty }
        discovery.cancel()

        #expect(login.serverURLInput == den.url.absoluteString)
    }
}

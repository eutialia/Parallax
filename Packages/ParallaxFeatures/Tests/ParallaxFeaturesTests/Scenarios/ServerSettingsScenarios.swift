import ParallaxFeatures
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import Testing
import ParallaxTestScaling

@MainActor
@Suite("Server settings", .scaledTimeLimit())
struct ServerSettingsScenarios {
    @Test("signing out of one of two servers keeps the other active, and the signed-out row offers sign-in again")
    func signOutKeepsTheOtherServer() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let attic = FakeJellyfinServer(name: "Attic").user("bo")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()
        let session = try #require(settings.sessions.first { $0.serverName == "Den" })

        await settings.signOut(session)

        #expect(settings.signOutErrorMessage == nil)
        #expect(world.app.router.destination == .home)
        #expect(world.app.router.activeServerID == ServerID(rawValue: attic.id))
        #expect(settings.sessions.map(\.serverName) == ["Attic"])
        #expect(await world.serverRows() == [
            AppWorld.ServerRow(name: "Attic", signedIn: true),
        ])
    }

    @Test("a server signed out by its token being revoked offers its own address to sign in again")
    func signedOutRowOffersSignInAgain() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let attic = FakeJellyfinServer(name: "Attic").user("bo")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        den.revokeAllTokens()
        await world.relaunch()
        try await world.until { world.app.router.activeServerID == ServerID(rawValue: attic.id) }
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()

        #expect(settings.signedOutServers.map(\.id) == [ServerID(rawValue: den.id)])
        guard case .jellyfin(let data)? = settings.signedOutServers.first?.kind else {
            Issue.record("the signed-out row is not a Jellyfin server")
            return
        }
        let login = LoginViewModel(app: world.app, prefilledServerURL: data.serverURL.absoluteString)
        login.username = "ana"
        await login.submit()

        #expect(await world.serverRows() == [
            AppWorld.ServerRow(name: "Den", signedIn: true),
            AppWorld.ServerRow(name: "Attic", signedIn: true),
        ])
    }

    @Test("removing the last server returns to login and its row is gone")
    func removingTheLastServerReturnsToLogin() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let settings = SettingsViewModel(app: world.app)
        await settings.refresh()
        let session = try #require(settings.sessions.first)

        await settings.signOut(session)

        #expect(world.app.router.destination == .login)
        #expect(settings.sessions.isEmpty)
        #expect(settings.signedOutServers.isEmpty)
        #expect(await world.serverRows() == [])
    }

    @Test("the server page reports Connected and the server's version")
    func serverPageShowsConnection() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try #require(await world.app.services.serverStore.active)
        let page = ServerSettingsModel(session: session, app: world.app)
        #expect(page.status == .checking)

        await page.probeServer()

        #expect(page.status == .connected)
        #expect(page.version == "10.10.7")
    }

    @Test("hiding a library shows N of M on the server page and survives a relaunch")
    func hiddenLibraryChangesSummaryAndPersists() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Movies").library("Shows")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try #require(await world.app.services.serverStore.active)
        let page = ServerSettingsModel(session: session, app: world.app)
        world.mount { await page.run() }
        #expect(page.visibleSummary == "All")

        let picker = VisibleLibrariesModel(session: session, app: world.app)
        await picker.load()
        #expect(picker.collections.map(\.name) == ["Movies", "Shows"])
        let tokenBefore = world.app.router.libraryReloadToken
        await picker.toggle(try #require(picker.collections.last))
        #expect(picker.hidden == ["library-Shows"])
        #expect(world.app.router.libraryReloadToken != tokenBefore)
        try await world.until { page.visibleSummary == "1 of 2" }

        await world.relaunch()
        let reopened = ServerSettingsModel(session: try #require(await world.app.services.serverStore.active), app: world.app)
        world.mount { await reopened.run() }
        try await world.until { reopened.visibleSummary == "1 of 2" }
    }
}

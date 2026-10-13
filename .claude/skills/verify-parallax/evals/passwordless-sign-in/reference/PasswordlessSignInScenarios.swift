import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Passwordless sign in", .timeLimit(.minutes(1)))
struct PasswordlessSignInScenarios {
    @Test("an account with no password can press Connect with just the server and username, and lands on home")
    func passwordlessAccountSignsIn() async throws {
        let demo = FakeJellyfinServer(name: "Demo").user("demo")
        let world = try await AppWorld.launch()
        let login = LoginViewModel(app: world.app)
        login.serverURLInput = demo.url.absoluteString
        login.username = "demo"

        #expect(login.canSubmitPassword)

        await login.submit()

        #expect(login.errorMessage == nil)
        #expect(world.app.router.destination == .home)
        #expect(await world.serverRows() == [AppWorld.ServerRow(name: "Demo", signedIn: true)])
    }

    @Test("Connect stays off until the form names a server and a username")
    func connectNeedsServerAndUsername() async throws {
        let demo = FakeJellyfinServer(name: "Demo").user("demo")
        let world = try await AppWorld.launch()
        let login = LoginViewModel(app: world.app)

        login.username = "demo"
        #expect(!login.canSubmitPassword)

        login.serverURLInput = demo.url.absoluteString
        login.username = "   "
        #expect(!login.canSubmitPassword)

        login.username = "demo"
        #expect(login.canSubmitPassword)
    }
}

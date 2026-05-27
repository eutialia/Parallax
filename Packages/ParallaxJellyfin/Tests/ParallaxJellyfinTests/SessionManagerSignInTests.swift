import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("SessionManager sign-in")
struct SessionManagerSignInTests {
    private func make() -> (SessionManager, ServerStore, FakeJellyfinClientFactory) {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        let keychain = Keychain(service: "com.lhdev.parallax.tests.\(suite)")
        let store = ServerStore(settings: settings, keychain: keychain)
        let factory = FakeJellyfinClientFactory()
        let manager = SessionManager(serverStore: store, factory: factory)
        return (manager, store, factory)
    }

    private func successAuthResult() -> AuthenticationResult {
        var user = UserDto()
        user.id = "user-1"
        user.name = "alice"
        var info = SessionInfoDto()
        info.id = "session-1"
        var result = AuthenticationResult()
        result.accessToken = "tok-from-server"
        result.serverID = "server-id-from-server"
        result.user = user
        result.sessionInfo = info
        return result
    }

    private func publicInfo(name: String = "Living Room") -> PublicSystemInfo {
        var info = PublicSystemInfo()
        info.serverName = name
        info.id = "server-id-from-server"
        return info
    }

    @Test("Successful sign-in returns a Session and writes through to ServerStore")
    func signInSuccess() async throws {
        let (manager, store, factory) = make()
        let url = URL(string: "https://jellyfin.example.com")!
        let client = factory.client(for: url)
        client.passwordSignInResult = .success(successAuthResult())
        client.publicSystemInfoResult = .success(publicInfo(name: "Living Room"))

        let session = try await manager.signIn(server: url, username: "alice", password: "hunter2")

        #expect(session.serverURL == url)
        #expect(session.serverName == "Living Room")
        #expect(session.user.id == "user-1")
        #expect(session.user.name == "alice")
        #expect(session.accessToken == "tok-from-server")
        #expect(session.id == ServerID(rawValue: "server-id-from-server"))

        let stored = await store.sessions
        #expect(stored.count == 1)
        #expect(stored.first?.id == session.id)
    }

    @Test("Invalid credentials surface as AppError.auth(.invalidCredentials)")
    func signInBadCredentials() async throws {
        let (manager, _, factory) = make()
        let url = URL(string: "https://jellyfin.example.com")!
        let client = factory.client(for: url)
        client.passwordSignInResult = .failure(JellyfinClient.ClientError.noAccessToken)

        await #expect(throws: AppError.self) {
            _ = try await manager.signIn(server: url, username: "alice", password: "wrong")
        }

        do {
            _ = try await manager.signIn(server: url, username: "alice", password: "wrong")
        } catch let error as AppError {
            if case .auth(let failure) = error {
                #expect(failure == .invalidCredentials)
            } else {
                Issue.record("expected .auth, got \(error)")
            }
        }
    }

    @Test("Sign-out removes the session from the store")
    func signOut() async throws {
        let (manager, store, factory) = make()
        let url = URL(string: "https://jellyfin.example.com")!
        let client = factory.client(for: url)
        client.passwordSignInResult = .success(successAuthResult())
        client.publicSystemInfoResult = .success(publicInfo())

        let session = try await manager.signIn(server: url, username: "alice", password: "hunter2")
        await manager.signOut(session)

        let remaining = await store.sessions
        #expect(remaining.isEmpty)
        #expect(client.signOutCalls == ["tok-from-server"])
    }

    @Test("Sign-out still removes locally if the server revoke call fails")
    func signOutLocalEvenIfRemoteFails() async throws {
        let (manager, store, factory) = make()
        let url = URL(string: "https://jellyfin.example.com")!
        let client = factory.client(for: url)
        client.passwordSignInResult = .success(successAuthResult())
        client.publicSystemInfoResult = .success(publicInfo())
        client.signOutResult = .failure(URLError(.notConnectedToInternet))

        let session = try await manager.signIn(server: url, username: "alice", password: "hunter2")
        await manager.signOut(session)

        let remaining = await store.sessions
        #expect(remaining.isEmpty)
    }
}

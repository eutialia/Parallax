import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

/// Shared scaffolding for both SessionManager suites — one store, one fake client factory, and the
/// two server payloads a sign-in composes a `Session` out of.
struct SessionManagerHarness {
    let manager: SessionManager
    let store: ServerStore
    let keychain: FakeKeychain
    let factory: FakeJellyfinClientFactory
    let serverURL = URL(string: "https://jellyfin.example.com")!

    init() {
        let storeHarness = JellyfinFixtures.serverStore("SessionManagerTests")
        store = storeHarness.store
        keychain = storeHarness.keychain
        factory = FakeJellyfinClientFactory()
        manager = SessionManager(serverStore: store, factory: factory)
    }

    var client: FakeJellyfinAuthClient { factory.client(for: serverURL) }

    /// A complete authentication response. `accessToken`/`serverID` are the two fields a Session
    /// cannot be built without, so they're the ones tests vary.
    static func authResult(
        accessToken: String? = "tok-from-server",
        serverID: String? = "server-id-from-server",
        userID: String? = "user-1",
        userName: String? = "alice"
    ) -> AuthenticationResult {
        var user = UserDto()
        user.id = userID
        user.name = userName
        var result = AuthenticationResult()
        result.accessToken = accessToken
        result.serverID = serverID
        result.user = (userID == nil && userName == nil) ? nil : user
        return result
    }

    static func publicInfo(name: String? = "Living Room", id: String? = "server-id-from-server") -> PublicSystemInfo {
        var info = PublicSystemInfo()
        info.serverName = name
        info.id = id
        return info
    }
}

@Suite("SessionManager sign-in")
struct SessionManagerSignInTests {
    @Test("Successful sign-in returns a Session and writes through to ServerStore")
    func signInSuccess() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(SessionManagerHarness.authResult())
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo(name: "Living Room"))

        let session = try await harness.manager.signIn(
            server: harness.serverURL,
            username: "alice",
            password: "hunter2"
        )

        #expect(session.serverURL == harness.serverURL)
        #expect(session.serverName == "Living Room")
        #expect(session.user.id == "user-1")
        #expect(session.user.name == "alice")
        #expect(session.accessToken == "tok-from-server")
        #expect(session.id == ServerID(rawValue: "server-id-from-server"))
        // The credential reached the client verbatim.
        #expect(harness.client.passwordSignInCalls.map(\.username) == ["alice"])
        #expect(harness.client.passwordSignInCalls.map(\.password) == ["hunter2"])

        #expect(await harness.store.sessions.map(\.id) == [session.id])
        #expect(await harness.manager.current?.id == session.id)
    }

    @Test("Invalid credentials surface as AppError.auth(.invalidCredentials)")
    func signInBadCredentials() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .failure(JellyfinClient.ClientError.noAccessToken)

        do {
            _ = try await harness.manager.signIn(server: harness.serverURL, username: "alice", password: "wrong")
            Issue.record("expected a throw")
        } catch let error as AppError {
            guard case .auth(.invalidCredentials) = error else {
                Issue.record("expected .auth(.invalidCredentials), got \(error)")
                return
            }
        }
        #expect(await harness.store.sessions.isEmpty)
    }

    /// Authentication succeeded but the follow-up public-info fetch failed — the server is real,
    /// the credential is good, and the failure is transport-shaped, so it must NOT read as a
    /// rejected password.
    @Test("A failed public-info fetch after authentication surfaces as the transport failure")
    func signInPublicInfoFailure() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(SessionManagerHarness.authResult())
        harness.client.publicSystemInfoResult = .failure(URLError(.timedOut))

        do {
            _ = try await harness.manager.signIn(server: harness.serverURL, username: "alice", password: "hunter2")
            Issue.record("expected a throw")
        } catch let error as AppError {
            guard case .network(let urlError) = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
            #expect(urlError.code == .timedOut)
        }
        #expect(await harness.store.sessions.isEmpty)
    }

    /// The server id is the store's primary key, so a response carrying neither an auth serverID
    /// nor a public-info id can't be persisted — better a named failure than a row keyed on
    /// something unstable.
    @Test("A response with no server id anywhere refuses to build a session")
    func signInWithoutServerID() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(SessionManagerHarness.authResult(serverID: nil))
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo(id: nil))

        await #expect(throws: AppError.self) {
            _ = try await harness.manager.signIn(server: harness.serverURL, username: "a", password: "b")
        }
    }

    /// `publicInfo.id` is the documented fallback for older servers whose auth response omits it.
    @Test("The public-info id is the fallback server id")
    func signInFallsBackToPublicInfoServerID() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(SessionManagerHarness.authResult(serverID: nil))
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo(id: "from-public-info"))

        let session = try await harness.manager.signIn(server: harness.serverURL, username: "a", password: "b")

        #expect(session.id == ServerID(rawValue: "from-public-info"))
    }

    /// A nameless server still has to render something in the sidebar, so the host stands in.
    @Test("A server with no name falls back to its host")
    func signInFallsBackToHostForName() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(SessionManagerHarness.authResult())
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo(name: nil))

        let session = try await harness.manager.signIn(server: harness.serverURL, username: "a", password: "b")

        #expect(session.serverName == harness.serverURL.host)
    }

    @Test("A response missing the user refuses to build a session")
    func signInWithoutUser() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(
            SessionManagerHarness.authResult(userID: nil, userName: nil)
        )
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo())

        await #expect(throws: AppError.self) {
            _ = try await harness.manager.signIn(server: harness.serverURL, username: "a", password: "b")
        }
    }

    @Test("Sign-out removes the session from the store")
    func signOut() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(SessionManagerHarness.authResult())
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo())

        let session = try await harness.manager.signIn(server: harness.serverURL, username: "alice", password: "hunter2")
        try await harness.manager.signOut(session)

        #expect(await harness.store.sessions.isEmpty)
        #expect(harness.client.signOutCalls == ["tok-from-server"])
    }

    /// The LOCAL revoke is what matters: an offline device must still be able to sign out, and the
    /// token slot must go with it — leaving it behind would let the next launch rebuild the session.
    @Test("Sign-out still removes locally, and deletes the token, if the server revoke fails")
    func signOutLocalEvenIfRemoteFails() async throws {
        let harness = SessionManagerHarness()
        harness.client.passwordSignInResult = .success(SessionManagerHarness.authResult())
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo())
        harness.client.signOutResult = .failure(URLError(.notConnectedToInternet))

        let session = try await harness.manager.signIn(server: harness.serverURL, username: "alice", password: "hunter2")
        try await harness.manager.signOut(session)

        #expect(await harness.store.sessions.isEmpty)
        #expect(await harness.store.servers.isEmpty)
        // The remote revoke was still attempted, with the right token.
        #expect(harness.client.signOutCalls == ["tok-from-server"])
        let stored: String? = try await harness.keychain.read(JellyfinFixtures.tokenKey(for: session.id))
        #expect(stored == nil)
    }
}

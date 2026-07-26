import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

/// The sign-in client, driven over a stubbed transport. It deliberately installs NO response
/// validator — a 401 here is a wrong password at the login form, not a dead session — so the
/// error shape is part of the contract, not an accident.
@Suite("DefaultJellyfinAuthClient — wire contract")
struct DefaultJellyfinAuthClientTests {

    private func makeClient(
        stub: StubHTTPTransport,
        quickConnectPolling: QuickConnectPolling = .default
    ) -> DefaultJellyfinAuthClient {
        DefaultJellyfinAuthClient(
            serverURL: stub.baseURL,
            identity: JellyfinFixtures.identity(deviceID: "dev-1"),
            sessionConfiguration: stub.configuration,
            quickConnectPolling: quickConnectPolling
        )
    }

    /// A budget with a negligible interval, so a test spends the polls instead of the wall clock.
    private func fastPolling(maxPolls: Int) -> QuickConnectPolling {
        QuickConnectPolling(interval: .milliseconds(1), maxPolls: maxPolls)
    }

    private func quickConnectEvents(of client: DefaultJellyfinAuthClient) async throws -> [QuickConnect.Event] {
        var collected: [QuickConnect.Event] = []
        for try await event in client.quickConnectEvents() { collected.append(event) }
        return collected
    }

    private func authResult(accessToken: String? = "tok-from-server") -> AuthenticationResult {
        var user = UserDto()
        user.id = "user-1"
        user.name = "alice"
        var result = AuthenticationResult()
        result.accessToken = accessToken
        result.serverID = "server-id-from-server"
        result.user = user
        return result
    }

    @Test("The client reports the server it was built for")
    func serverURLIsTheConfiguredOne() {
        let stub = StubHTTPTransport()
        #expect(makeClient(stub: stub).serverURL == stub.baseURL)
    }

    @Test("Password sign-in POSTs the credential to AuthenticateByName and returns the result")
    func passwordSignIn() async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded(authResult()))

        let result = try await makeClient(stub: stub).signIn(username: "alice", password: "hunter2")

        let request = try stub.onlyExchange()
        #expect(request.method == "POST")
        #expect(request.path == "/Users/AuthenticateByName")
        let body = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["Username"] as? String == "alice")
        #expect(json["Pw"] as? String == "hunter2")
        #expect(result.accessToken == "tok-from-server")
        #expect(result.user?.id == "user-1")
        // The device identity has to travel with the request, or the server can't attribute the
        // session to this device (and `stopEncoding`'s deviceId filter would never match).
        let authorization = request.headers["Authorization"] ?? ""
        #expect(authorization.hasPrefix("MediaBrowser "))
        #expect(authorization.contains("DeviceId=dev-1"))
        #expect(authorization.contains("Client=Parallax"))
    }

    /// The SDK treats a 2xx without an access token as `ClientError.noAccessToken`, which
    /// `ErrorMapping` renders as "incorrect username or password".
    @Test("A tokenless success is surfaced as a client error, not a signed-in session")
    func passwordSignInWithoutToken() async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded(authResult(accessToken: nil)))

        await #expect(throws: JellyfinClient.ClientError.noAccessToken) {
            _ = try await makeClient(stub: stub).signIn(username: "alice", password: "nope")
        }
    }

    /// The handshake this client runs itself (initiate → poll until approved), so the endpoints and
    /// the event order are the contract: the code has to reach the user BEFORE any polling, and the
    /// secret that comes back from the approving response is the one handed on for the exchange.
    @Test("Quick Connect initiates, shows the code, then polls until the server approves")
    func quickConnectHandshake() async throws {
        let stub = StubHTTPTransport()
        stub.enqueue(
            .encoded(QuickConnectResult(code: "AB12", secret: "pending-secret")),
            .encoded(QuickConnectResult(isAuthenticated: false, secret: "pending-secret")),
            .encoded(QuickConnectResult(isAuthenticated: true, secret: "approved-secret"))
        )

        let events = try await quickConnectEvents(of: makeClient(stub: stub, quickConnectPolling: fastPolling(maxPolls: 5)))

        #expect(events == [.polling(code: "AB12"), .authenticated(secret: "approved-secret")])
        let exchanges = stub.exchanges
        #expect(exchanges.count == 3)
        #expect(exchanges.first?.method == "POST")
        #expect(exchanges.first?.path == "/QuickConnect/Initiate")
        // Every poll asks about the secret the initiate call handed back, unauthenticated —
        // the state endpoint is the only thing standing between a code and a session.
        #expect(exchanges.dropFirst().allSatisfy { $0.method == "GET" && $0.path == "/QuickConnect/Connect" })
        #expect(exchanges.dropFirst().allSatisfy { $0.query("secret") == "pending-secret" })
    }

    /// Expiry is THIS layer's verdict — it owns the deadline — so it arrives as a typed
    /// `AppError`, not as something a caller has to recognise by stringifying it. The budget is
    /// also the loop bound: `maxPolls` attempts and not one more.
    @Test("A code nobody approves expires after exactly its polling budget", arguments: [1, 3])
    func quickConnectExpiresAfterItsBudget(maxPolls: Int) async throws {
        let stub = StubHTTPTransport()
        stub.enqueue(.encoded(QuickConnectResult(code: "AB12", secret: "pending-secret")))
        stub.always(.encoded(QuickConnectResult(isAuthenticated: false)))

        let thrown = await #expect(throws: AppError.self) {
            _ = try await self.quickConnectEvents(of: self.makeClient(stub: stub, quickConnectPolling: self.fastPolling(maxPolls: maxPolls)))
        }

        guard case .auth(let failure) = thrown else {
            Issue.record("expected .auth, got \(String(describing: thrown))")
            return
        }
        #expect(failure == .quickConnectExpired)
        #expect(stub.exchanges.count == 1 + maxPolls)
    }

    /// A server that accepts the request but names no code leaves nothing to show and nothing to
    /// poll. That's a server/transport problem, not an auth verdict — mapping it to any `.auth`
    /// case would tell the user their pairing was refused when it never started.
    @Test("An initiate response with no code fails without polling, and not as an auth verdict")
    func quickConnectWithoutCode() async throws {
        let stub = StubHTTPTransport()
        stub.always(.json("{}"))

        let thrown = await #expect(throws: AppError.self) {
            _ = try await self.quickConnectEvents(of: self.makeClient(stub: stub, quickConnectPolling: self.fastPolling(maxPolls: 3)))
        }

        guard case .unexpected = thrown else {
            Issue.record("expected .unexpected, got \(String(describing: thrown))")
            return
        }
        #expect(try stub.onlyExchange().path == "/QuickConnect/Initiate")
    }

    @Test("Quick Connect sign-in POSTs the approved secret")
    func quickConnectSignIn() async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded(authResult(accessToken: "tok-qc")))

        let result = try await makeClient(stub: stub).signIn(quickConnectSecret: "secret-xyz")

        let request = try stub.onlyExchange()
        #expect(request.path == "/Users/AuthenticateWithQuickConnect")
        let secretBody = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: secretBody) as? [String: Any])
        #expect(json["Secret"] as? String == "secret-xyz")
        #expect(result.accessToken == "tok-qc")
    }

    /// The revoke is a one-shot authed call on a throwaway client: the token is carried purely so
    /// the server can kill it, and never enters the Keychain by this path.
    @Test("Sign-out revokes exactly the token it was handed")
    func signOut() async throws {
        let stub = StubHTTPTransport()
        stub.always(.noContent)

        try await makeClient(stub: stub).signOut(accessToken: "tok-to-revoke")

        let request = try stub.onlyExchange()
        #expect(request.method == "DELETE")
        #expect(request.path == "/Auth/Keys/tok-to-revoke")
        #expect(request.headers["Authorization"]?.contains("Token=tok-to-revoke") == true)
    }

    /// No token, nothing to revoke — but the SDK still clears its own state, so the call must not
    /// invent a request against a key that doesn't exist.
    @Test("Public info is fetched without a token on the wire")
    func publicInfoIsUnauthenticated() async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded(PublicSystemInfo()))

        _ = try await makeClient(stub: stub).fetchPublicSystemInfo()

        let authorization = try stub.onlyExchange().headers["Authorization"] ?? ""
        #expect(authorization.contains("Token=") == false)
    }

    @Test("Public system info is fetched unauthenticated from the public endpoint")
    func publicSystemInfo() async throws {
        let stub = StubHTTPTransport()
        var info = PublicSystemInfo()
        info.serverName = "Living Room"
        info.id = "server-id"
        info.version = "10.11.0"
        stub.always(.encoded(info))

        let fetched = try await makeClient(stub: stub).fetchPublicSystemInfo()

        #expect(try stub.onlyExchange().path == "/System/Info/Public")
        #expect(fetched.serverName == "Living Room")
        #expect(fetched.id == "server-id")
    }

    /// `serverVersion()` is the protocol extension the server-detail screen calls so it never has
    /// to import the SDK; a successful fetch doubles as the point-in-time reachability proof.
    @Test("serverVersion() projects the version out of the public info payload")
    func serverVersion() async throws {
        let stub = StubHTTPTransport()
        var info = PublicSystemInfo()
        info.version = "10.11.0"
        stub.always(.encoded(info))

        #expect(try await makeClient(stub: stub).serverVersion() == "10.11.0")
    }

    @Test("An unreachable server propagates as a thrown error from serverVersion()")
    func serverVersionPropagatesFailure() async throws {
        let stub = StubHTTPTransport()
        stub.always(.json("{}", status: 500))
        await #expect(throws: (any Error).self) {
            _ = try await makeClient(stub: stub).serverVersion()
        }
    }
}

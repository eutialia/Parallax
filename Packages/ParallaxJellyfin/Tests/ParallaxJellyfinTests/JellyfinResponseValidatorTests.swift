import Foundation
import Testing
import Get
import ParallaxCore
@testable import ParallaxJellyfin

/// The single chokepoint that turns a server-rejected token into a signal the app can act on.
/// Everything here is about one distinction: 401 is recoverable ONLY by signing in again, so it
/// must be reported and named; every other failure is transient and must not sign anyone out.
@Suite("Jellyfin response validation")
struct JellyfinResponseValidatorTests {
    private let serverID = ServerID(rawValue: "server-1")

    /// An ephemeral session, never `URLSession.shared`: the `task` argument only exists to satisfy
    /// the `Get` hook's signature (the validator never touches it), and reaching into the shared
    /// session would couple every case here to global URL-loading state.
    private static let session = URLSession(configuration: .ephemeral)

    private func validate(
        status: Int,
        headers: [String: String]? = nil,
        onTokenRejected: @escaping @Sendable (ServerID) -> Void = { _ in }
    ) throws {
        let validator = JellyfinResponseValidator(serverID: serverID, onTokenRejected: onTokenRejected)
        let url = URL(string: "https://jellyfin.example.test/Users/Views")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        try validator.client(
            APIClient(baseURL: url),
            validateResponse: response,
            data: Data(),
            task: Self.session.dataTask(with: url)
        )
    }

    @Test("A 2xx response passes without reporting anything", arguments: [200, 204, 299])
    func successPasses(status: Int) throws {
        let reported = ReportedServerIDs()
        try validate(status: status) { reported.record($0) }
        #expect(reported.ids.isEmpty)
    }

    @Test("A 401 reports the server and surfaces as an expired session")
    func unauthorizedReportsAndNames() {
        let reported = ReportedServerIDs()
        do {
            try validate(status: 401) { reported.record($0) }
            Issue.record("expected a throw")
        } catch let error as AppError {
            guard case .auth(.tokenInvalidated) = error else {
                Issue.record("expected .auth(.tokenInvalidated), got \(error)")
                return
            }
            // The message the user actually reads has to say what to DO; the generic 401 mapping
            // ("your server returned an error") sends them nowhere. Compared against the copy the
            // failure itself owns, not a duplicate of it.
            #expect(error.userMessage == AuthFailure.tokenInvalidated.userMessage)
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        #expect(reported.ids == [serverID])
    }

    /// The one that must not over-fire. A 500 or a 404 is transient or item-specific; signing the
    /// user out over it would take down a perfectly good server on a single bad request.
    @Test("Other failures throw a plain server error and never report a rejection", arguments: [403, 404, 500, 503])
    func otherFailuresDoNotSignOut(status: Int) {
        let reported = ReportedServerIDs()
        do {
            try validate(status: status) { reported.record($0) }
            Issue.record("expected a throw for HTTP \(status)")
        } catch let error as AppError {
            guard case .server(let code, _) = error else {
                Issue.record("expected .server for HTTP \(status), got \(error)")
                return
            }
            #expect(code == status)
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        #expect(reported.ids.isEmpty)
    }

    /// The destructive false positive: a Jellyfin behind an auth gateway (Authelia, Authentik, a
    /// reverse proxy with basic auth) answers 401 for ITS OWN missing credential while the Jellyfin
    /// token is perfectly good. Signing out there would delete a working token and route the user
    /// to a sign-in that 401s too. RFC 7235 §3.1 makes `WWW-Authenticate` mandatory on a real
    /// challenge, and Jellyfin's own token rejection sends none — so its presence is the
    /// discriminator. The header NAME is matched case-insensitively because HTTP field names are,
    /// and `HTTPURLResponse` preserves whatever casing the server sent.
    @Test(
        "A 401 carrying an auth challenge is an upstream gateway — never a rejected token",
        arguments: ["WWW-Authenticate", "www-authenticate", "Www-Authenticate"],
        ["Basic realm=\"proxy\"", "Bearer", "Digest realm=\"gw\", nonce=\"abc\""]
    )
    func gatewayChallengeDoesNotSignOut(headerName: String, challenge: String) {
        let reported = ReportedServerIDs()
        do {
            try validate(status: 401, headers: [headerName: challenge]) { reported.record($0) }
            Issue.record("expected a throw — a gateway 401 is still a failed request")
        } catch let error as AppError {
            guard case .server(let code, _) = error else {
                Issue.record("expected .server(401), got \(error)")
                return
            }
            #expect(code == 401)
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        // The load-bearing assertion: nothing was reported, so no session is dropped and no
        // Keychain token is deleted.
        #expect(reported.ids.isEmpty)
    }
}

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
            task: URLSession.shared.dataTask(with: url)
        )
    }

    @Test("A 2xx response passes without reporting anything", arguments: [200, 204, 299])
    func successPasses(status: Int) throws {
        let reported = Reported()
        try validate(status: status) { reported.record($0) }
        #expect(reported.ids.isEmpty)
    }

    @Test("A 401 reports the server and surfaces as an expired session")
    func unauthorizedReportsAndNames() {
        let reported = Reported()
        #expect(throws: AppError.self) {
            try validate(status: 401) { reported.record($0) }
        }
        #expect(reported.ids == [serverID])

        // The message the user actually reads has to say what to DO. "Your server returned an
        // error" (the old generic 401 mapping) sends them nowhere.
        do {
            try validate(status: 401)
            Issue.record("expected a throw")
        } catch let error as AppError {
            guard case .auth(.tokenInvalidated) = error else {
                Issue.record("expected .auth(.tokenInvalidated), got \(error)")
                return
            }
            #expect(error.userMessage == "Your session expired. Sign in again.")
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
    }

    /// The one that must not over-fire. A 500 or a 404 is transient or item-specific; signing the
    /// user out over it would take down a perfectly good server on a single bad request.
    @Test("Other failures throw a plain server error and never report a rejection", arguments: [403, 404, 500, 503])
    func otherFailuresDoNotSignOut(status: Int) {
        let reported = Reported()
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

    /// The destructive false positive: a Jellyfin behind an auth gateway (Authelia, a reverse proxy
    /// with basic auth) answers 401 for ITS OWN missing credential while the Jellyfin token is
    /// perfectly good. Signing out there would delete a working token and route the user to a
    /// sign-in that 401s too. RFC 7235 §3.1 makes `WWW-Authenticate` mandatory on a real challenge,
    /// and Jellyfin's own token rejection sends none — so its presence is the discriminator.
    @Test(
        "A 401 carrying an auth challenge is an upstream gateway — never a rejected token",
        arguments: ["Basic realm=\"proxy\"", "Bearer", "Digest realm=\"gw\", nonce=\"abc\""]
    )
    func gatewayChallengeDoesNotSignOut(challenge: String) {
        let reported = Reported()
        do {
            try validate(status: 401, headers: ["WWW-Authenticate": challenge]) { reported.record($0) }
            Issue.record("expected a throw")
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

    /// Header matching must be case-insensitive — HTTP field names are, and `HTTPURLResponse`
    /// preserves whatever casing the server sent.
    @Test("The challenge check doesn't depend on header casing")
    func challengeMatchIsCaseInsensitive() {
        let reported = Reported()
        try? validate(status: 401, headers: ["www-authenticate": "Basic realm=\"proxy\""]) { reported.record($0) }
        #expect(reported.ids.isEmpty)
    }

    /// Collects reported ids across the validator's `@Sendable` callback boundary.
    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ServerID] = []
        var ids: [ServerID] { lock.lock(); defer { lock.unlock() }; return storage }
        func record(_ id: ServerID) { lock.lock(); storage.append(id); lock.unlock() }
    }
}

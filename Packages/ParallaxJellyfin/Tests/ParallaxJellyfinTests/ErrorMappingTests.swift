import Foundation
import Testing
import Get
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("Error mapping")
struct ErrorMappingTests {
    /// The auth-shaped mappings are all the same question — "which AuthFailure does this error
    /// mean?" — and each answer drives different recovery copy, so they're one table.
    @Test(
        "Auth-shaped errors map to the failure whose recovery advice fits",
        arguments: [
            // The SDK's tokenless-success error: the login form rejected the credential.
            (AuthCase.noAccessToken, AuthFailure.invalidCredentials),
            // A raw 401 only reaches here from a client with NO validator — sign-in and Quick
            // Connect — so it's a rejected credential, not an expired session. "Sign in again"
            // would be nonsense advice to someone already signing in.
            (.unauthorizedWithoutValidator, .invalidCredentials),
            // A typed AppError from the validator must pass through, not be re-derived.
            (.alreadyTypedAppError, .tokenInvalidated),
            // Same passthrough, from the other typed producer: `DefaultJellyfinAuthClient` throws
            // the expiry verdict itself once its polling budget is spent, and `SessionManager`
            // keys `.expired` off exactly this case surviving the mapping.
            (.quickConnectBudgetSpent, .quickConnectExpired),
        ]
    )
    func authFailureMapping(input: AuthCase, expected: AuthFailure) {
        let mapped = ErrorMapping.appError(from: input.error)
        guard case .auth(let failure) = mapped else {
            Issue.record("expected .auth for \(input), got \(mapped)")
            return
        }
        #expect(failure == expected)
    }

    enum AuthCase: Sendable {
        case noAccessToken, unauthorizedWithoutValidator, alreadyTypedAppError, quickConnectBudgetSpent

        var error: Error {
            switch self {
            case .noAccessToken: JellyfinClient.ClientError.noAccessToken
            case .unauthorizedWithoutValidator: APIError.unacceptableStatusCode(401)
            case .alreadyTypedAppError: AppError.auth(.tokenInvalidated)
            case .quickConnectBudgetSpent: AppError.auth(.quickConnectExpired)
            }
        }
    }

    @Test("URLError maps to AppError.network with its code preserved")
    func urlError() {
        let mapped = ErrorMapping.appError(from: URLError(.notConnectedToInternet))
        guard case .network(let inner) = mapped else {
            Issue.record("expected .network, got \(mapped)")
            return
        }
        #expect(inner.code == .notConnectedToInternet)
    }

    @Test("Unknown errors fall through to .unexpected with the underlying preserved")
    func unknown() {
        struct WeirdError: Error {}
        let mapped = ErrorMapping.appError(from: WeirdError())
        guard case .unexpected(let note, let underlying) = mapped else {
            Issue.record("expected .unexpected, got \(mapped)")
            return
        }
        #expect(note.contains("WeirdError"))
        #expect(underlying?.diagnosticDescription.contains("WeirdError") == true)
    }

    @Test("APIError.unacceptableStatusCode carries its status through to .server", arguments: [404, 500, 503])
    func unacceptableStatusCode(status: Int) {
        let mapped = ErrorMapping.appError(from: APIError.unacceptableStatusCode(status))
        guard case .server(let code, let message) = mapped else {
            Issue.record("expected .server, got \(mapped)")
            return
        }
        #expect(code == status)
        #expect(message == nil)
    }

    /// The mapping classifies by TYPE, never by what an error happens to be called. It used to
    /// recognise the SDK's internal Quick Connect error by stringifying it, so any error whose
    /// name and description looked the part was silently promoted to an auth verdict — and one
    /// upstream rename would have silently demoted the real thing. Names carry no authority.
    @Test("An error is never classified by its type name or description")
    func namesCarryNoAuthority() {
        struct QuickConnectError: Error, CustomStringConvertible { let description = "maxPollingHit" }
        let mapped = ErrorMapping.appError(from: QuickConnectError())
        guard case .unexpected(let note, _) = mapped else {
            Issue.record("expected .unexpected (an unknown type), got \(mapped)")
            return
        }
        #expect(note.contains("QuickConnectError"))
    }
}

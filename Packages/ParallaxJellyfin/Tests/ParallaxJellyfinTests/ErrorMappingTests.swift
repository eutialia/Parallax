import Foundation
import Testing
import Get
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test("URLError maps to AppError.network")
    func urlError() {
        let urlErr = URLError(.notConnectedToInternet)
        let app = ErrorMapping.appError(from: urlErr)
        if case .network(let inner) = app {
            #expect(inner.code == .notConnectedToInternet)
        } else {
            Issue.record("expected .network, got \(app)")
        }
    }

    @Test("JellyfinClient.ClientError.noAccessToken maps to invalidCredentials")
    func noAccessToken() {
        let app = ErrorMapping.appError(from: JellyfinClient.ClientError.noAccessToken)
        if case .auth(let failure) = app {
            #expect(failure == .invalidCredentials)
        } else {
            Issue.record("expected .auth, got \(app)")
        }
    }

    @Test("Unknown errors fall through to .unexpected with the underlying preserved")
    func unknown() {
        struct WeirdError: Error {}
        let app = ErrorMapping.appError(from: WeirdError())
        if case .unexpected(let note, let underlying) = app {
            #expect(note.contains("WeirdError"))
            #expect(underlying?.diagnosticDescription.contains("WeirdError") == true)
        } else {
            Issue.record("expected .unexpected, got \(app)")
        }
    }

    @Test("APIError.unacceptableStatusCode carries its status through to .server")
    func unacceptableStatusCode() {
        let app = ErrorMapping.appError(from: APIError.unacceptableStatusCode(404))
        if case .server(let code, let message) = app {
            #expect(code == 404)
            #expect(message == nil)
        } else {
            Issue.record("expected .server, got \(app)")
        }
    }

    /// The only clients that still reach `ErrorMapping` with a raw `APIError` are the ones with
    /// no `JellyfinResponseValidator`: sign-in and Quick Connect. A 401 there is a rejected
    /// credential at the login form, NOT an expired session — "sign in again" would be nonsense
    /// advice to someone already signing in.
    @Test("A 401 outside a live session reads as a rejected credential, not an expired session")
    func unauthorizedDuringSignInIsInvalidCredentials() {
        let app = ErrorMapping.appError(from: APIError.unacceptableStatusCode(401))
        if case .auth(let failure) = app {
            #expect(failure == .invalidCredentials)
        } else {
            Issue.record("expected .auth(.invalidCredentials), got \(app)")
        }
    }

    /// `JellyfinResponseValidator` throws typed `AppError`s straight from the response hook;
    /// `appError(from:)` must pass those through untouched rather than re-deriving them.
    @Test("An AppError thrown by the response validator passes through unchanged")
    func appErrorPassesThrough() {
        let app = ErrorMapping.appError(from: AppError.auth(.tokenInvalidated))
        if case .auth(let failure) = app {
            #expect(failure == .tokenInvalidated)
        } else {
            Issue.record("expected .auth(.tokenInvalidated), got \(app)")
        }
    }

    @Test("Quick Connect maxPollingHit maps to .auth(.quickConnectExpired)")
    func quickConnectExpired() {
        struct QuickConnectError: Error, CustomStringConvertible {
            var description: String { "maxPollingHit" }
        }
        let app = ErrorMapping.appError(from: QuickConnectError())
        if case .auth(let failure) = app {
            #expect(failure == .quickConnectExpired)
        } else {
            Issue.record("expected .auth(.quickConnectExpired), got \(app)")
        }
    }

    @Test("Quick Connect retrievingCodeFailed falls through to .unexpected (not .auth) — server/transport problems must not be mis-rendered as 'rejected'")
    func retrievingCodeFailedFallsThrough() {
        struct QuickConnectError: Error, CustomStringConvertible {
            var description: String { "retrievingCodeFailed" }
        }
        let app = ErrorMapping.appError(from: QuickConnectError())
        if case .auth = app {
            Issue.record("retrievingCodeFailed should NOT map to .auth — it's a server/transport failure")
        }
    }
}

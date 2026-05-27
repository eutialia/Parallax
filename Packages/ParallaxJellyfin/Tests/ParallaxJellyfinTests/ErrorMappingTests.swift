import Foundation
import Testing
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

    @Test("Synthetic unacceptableStatusCode(404) maps to .server(404, nil)")
    func unacceptableStatusCode() {
        struct FakeAPIError: Error, CustomStringConvertible {
            var description: String { "unacceptableStatusCode(404)" }
        }
        let app = ErrorMapping.appError(from: FakeAPIError())
        if case .server(let code, let message) = app {
            #expect(code == 404)
            #expect(message == nil)
        } else {
            Issue.record("expected .server, got \(app)")
        }
    }

    @Test("unacceptableStatusCode parser ignores unrelated digits in the description")
    func unacceptableStatusCodeIgnoresOtherDigits() {
        struct FakeAPIError: Error, CustomStringConvertible {
            // Port 8096 and a byte count are present; only the 503 inside the
            // unacceptableStatusCode(...) call should be extracted.
            var description: String { "host=127.0.0.1:8096 bytes=1024 unacceptableStatusCode(503)" }
        }
        let app = ErrorMapping.appError(from: FakeAPIError())
        if case .server(let code, _) = app {
            #expect(code == 503)
        } else {
            Issue.record("expected .server(503,_), got \(app)")
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

    @Test("Quick Connect retrievingCodeFailed maps to .auth(.quickConnectRejected)")
    func quickConnectRejected() {
        struct QuickConnectError: Error, CustomStringConvertible {
            var description: String { "retrievingCodeFailed" }
        }
        let app = ErrorMapping.appError(from: QuickConnectError())
        if case .auth(let failure) = app {
            #expect(failure == .quickConnectRejected)
        } else {
            Issue.record("expected .auth(.quickConnectRejected), got \(app)")
        }
    }
}

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
}

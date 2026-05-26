import Testing
import Foundation
@testable import ParallaxCore

@Suite("AppError")
struct AppErrorTests {
    @Test("userMessage is safe for display and does not leak internals")
    func userMessageSafety() {
        let netErr = URLError(.notConnectedToInternet)
        let err = AppError.network(netErr)
        #expect(err.userMessage == "Couldn't reach the server. Check your internet connection.")
        #expect(!err.userMessage.contains("URLError"))
        #expect(!err.userMessage.contains("-1009"))
    }

    @Test("auth.invalidCredentials maps to a clear user message")
    func authMessage() {
        let err = AppError.auth(.invalidCredentials)
        #expect(err.userMessage == "Incorrect username or password.")
    }

    @Test("server error includes status code in diagnostic but not user message")
    func serverDiagnosticVsUser() {
        let err = AppError.server(statusCode: 503, message: "DB down")
        #expect(err.userMessage == "The server is having trouble responding. Try again in a moment.")
        #expect(err.diagnosticDescription.contains("503"))
        #expect(err.diagnosticDescription.contains("DB down"))
    }

    @Test("unexpected error preserves the underlying description in diagnostic")
    func unexpectedWithUnderlying() {
        struct Underlying: Error { let note: String }
        let err = AppError.unexpected("calibration failed", underlying: AnySendableError(Underlying(note: "x")))
        #expect(err.userMessage == "Something went wrong. Please try again.")
        #expect(err.diagnosticDescription.contains("calibration failed"))
    }
}

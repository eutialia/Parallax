import Foundation
import Testing
@testable import ParallaxCore

@Suite("AppError")
struct AppErrorTests {
    private static let authFailures: [AuthFailure] = [
        .invalidCredentials, .quickConnectExpired, .tokenInvalidated, .credentialUnavailable,
    ]
    private static let sourceFailures: [SourceFailure] = [.notFound, .permissionDenied, .connectionLost]
    private static let playbackFailures: [PlaybackFailure] = [
        .decodeFailed, .unsupportedFormat, .resourceUnavailable, .audioSessionFailed,
    ]
    private static let urlErrorCodes: [URLError.Code] = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotFindHost, .cannotConnectToHost, .badServerResponse,
    ]

    /// Every case the app can surface, for the invariants that must hold across all of them.
    private static let everyCase: [AppError] =
        urlErrorCodes.map { .network(URLError($0)) }
        + authFailures.map { .auth($0) }
        + sourceFailures.map { .source($0) }
        + playbackFailures.map { .playback($0) }
        + [
            .server(statusCode: 503, message: "DB down"),
            .unexpected("calibration failed", underlying: AnySendableError(SampleError(note: "secret"))),
        ]

    private struct SampleError: Error { let note: String }

    // MARK: - Transport mapping

    /// The literals ARE the spec here: this is the URLError-code → copy table, the only place in
    /// `AppError` where a message is chosen rather than delegated.
    @Test("each transport failure class gets its own recovery-shaped message", arguments: [
        (URLError.Code.notConnectedToInternet, "Couldn't reach your server. Check your connection."),
        (.networkConnectionLost, "Couldn't reach your server. Check your connection."),
        (.timedOut, "Your server took too long to respond. Try again."),
        (.cannotFindHost, "Couldn't find your server. Check the URL, or make sure it's online."),
        (.cannotConnectToHost, "Couldn't find your server. Check the URL, or make sure it's online."),
        (.badServerResponse, "The connection failed. Try again."),   // unmapped → generic
    ])
    func networkMessagePerCode(code: URLError.Code, expected: String) {
        #expect(AppError.network(URLError(code)).userMessage == expected)
    }

    // MARK: - Delegation

    @Test("auth errors show the failure's own message", arguments: Self.authFailures)
    func authDelegates(failure: AuthFailure) {
        #expect(AppError.auth(failure).userMessage == failure.userMessage)
    }

    @Test("source errors show the failure's own message", arguments: Self.sourceFailures)
    func sourceDelegates(failure: SourceFailure) {
        #expect(AppError.source(failure).userMessage == failure.userMessage)
    }

    @Test("playback errors show the failure's own message", arguments: Self.playbackFailures)
    func playbackDelegates(failure: PlaybackFailure) {
        #expect(AppError.playback(failure).userMessage == failure.userMessage)
    }

    // MARK: - Cross-case invariants

    /// A shared message would let one failure masquerade as another — an audio-session failure
    /// once read as a connectivity problem, which sent people to their router instead of Settings.
    @Test("every failure reason carries a distinct message")
    func messagesAreDistinctPerReason() {
        let messages = Self.authFailures.map(\.userMessage)
            + Self.sourceFailures.map(\.userMessage)
            + Self.playbackFailures.map(\.userMessage)
        #expect(Set(messages).count == messages.count)
    }

    @Test("no user-facing message leaks a code, a type name or an underlying error",
          arguments: Self.everyCase)
    func userMessagesAreSafeForDisplay(error: AppError) {
        let message = error.userMessage
        #expect(message.isEmpty == false)
        #expect(message.contains("URLError") == false)
        #expect(message.contains("Error Domain") == false)
        #expect(message.contains("503") == false)
        #expect(message.contains("DB down") == false)
        #expect(message.contains("secret") == false)
        #expect(message.contains("calibration failed") == false)
        #expect(message.contains(where: \.isNumber) == false, "no numeric code should reach the UI")
    }

    @Test("every case labels its own subsystem in the diagnostic", arguments: Self.everyCase)
    func diagnosticIsSubsystemTagged(error: AppError) {
        let subsystems = ["network:", "auth:", "server:", "source:", "playback:", "unexpected:"]
        #expect(subsystems.contains { error.diagnosticDescription.hasPrefix($0) })
    }

    // MARK: - Diagnostic-only detail

    @Test("a server error keeps its status and server text in the diagnostic only")
    func serverDetailIsDiagnosticOnly() {
        let error = AppError.server(statusCode: 503, message: "DB down")
        #expect(error.diagnosticDescription.contains("503"))
        #expect(error.diagnosticDescription.contains("DB down"))
    }

    @Test("a server error with no server text still reports its status")
    func serverWithoutMessage() {
        #expect(AppError.server(statusCode: 404, message: nil).diagnosticDescription.contains("404"))
    }

    @Test("an unexpected error preserves both its note and the underlying description")
    func unexpectedPreservesUnderlying() {
        let error = AppError.unexpected(
            "calibration failed", underlying: AnySendableError(SampleError(note: "secret"))
        )
        #expect(error.diagnosticDescription.contains("calibration failed"))
        #expect(error.diagnosticDescription.contains("secret"))
    }

    @Test("an unexpected error with no underlying records that fact rather than dropping the field")
    func unexpectedWithoutUnderlying() {
        let error = AppError.unexpected("no context", underlying: nil)
        #expect(error.diagnosticDescription.contains("underlying=nil"))
    }

    @Test("a transport diagnostic carries the URLError code the user message withholds")
    func networkDiagnosticCarriesCode() {
        let code = URLError.Code.notConnectedToInternet
        let diagnostic = AppError.network(URLError(code)).diagnosticDescription
        #expect(diagnostic.contains(String(code.rawValue)))
    }
}

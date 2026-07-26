import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

@Suite("SessionManager Quick Connect")
struct SessionManagerQuickConnectTests {
    private func statuses(of harness: SessionManagerHarness) async -> [QuickConnectStatus] {
        var collected: [QuickConnectStatus] = []
        for await status in await harness.manager.signInWithQuickConnect(server: harness.serverURL) {
            collected.append(status)
        }
        return collected
    }

    @Test("Full Quick Connect happy path: code → signedIn")
    func happyPath() async throws {
        let harness = SessionManagerHarness()
        harness.client.quickConnectEventsToYield = [
            .success(.polling(code: "AB12")),
            .success(.authenticated(secret: "secret-xyz")),
        ]
        harness.client.quickConnectSignInResult = .success(
            SessionManagerHarness.authResult(accessToken: "tok-qc", serverID: "server-qc")
        )
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo(name: "Cinema", id: "server-qc"))

        let collected = await statuses(of: harness)

        #expect(collected.first == .waitingForCode)
        #expect(collected.contains(.polling(code: "AB12")))
        guard case .signedIn(let session) = collected.last else {
            Issue.record("expected last status to be .signedIn, got \(String(describing: collected.last))")
            return
        }
        #expect(session.serverName == "Cinema")
        #expect(session.accessToken == "tok-qc")
        // The approved secret from the stream is what gets exchanged for a token.
        #expect(harness.client.quickConnectSignInCalls == ["secret-xyz"])
        #expect(await harness.store.sessions.count == 1)
    }

    /// Only the auth client's own expiry verdict (`AppError.auth(.quickConnectExpired)`, thrown
    /// when its polling budget is spent) may surface as `.expired`. Every other terminating error
    /// is a transport/server problem and must report the mapped reason instead of telling the user
    /// their pairing timed out.
    @Test(
        "A terminating stream error is classified, never guessed at",
        arguments: [
            (QuickConnectFailure.expiredCode, QuickConnectStatus.expired),
            (.codeFetchFailed, .failed(reason: AppError.unexpected("", underlying: nil).userMessage)),
            (.offline, .failed(reason: AppError.network(URLError(.notConnectedToInternet)).userMessage)),
        ]
    )
    func streamFailureClassification(failure: QuickConnectFailure, expected: QuickConnectStatus) async throws {
        let harness = SessionManagerHarness()
        harness.client.quickConnectEventsToYield = [
            .success(.polling(code: "AB12")),
            .failure(failure.error),
        ]

        let collected = await statuses(of: harness)

        #expect(collected.last == expected)
        #expect(await harness.store.sessions.isEmpty)
    }

    enum QuickConnectFailure: Sendable {
        case expiredCode, codeFetchFailed, offline

        var error: Error {
            switch self {
            case .expiredCode: AppError.auth(.quickConnectExpired)
            case .codeFetchFailed:
                AppError.unexpected("Jellyfin Quick Connect: server returned no pairing code", underlying: nil)
            case .offline: URLError(.notConnectedToInternet)
            }
        }
    }

    /// A stream that ends without ever approving the device (server restart, admin denial) must
    /// name that outcome rather than hanging on `.waitingForCode` forever.
    @Test("A stream that ends with no secret reports a failure")
    func streamEndsWithoutApproval() async throws {
        let harness = SessionManagerHarness()
        harness.client.quickConnectEventsToYield = [.success(.polling(code: "AB12"))]

        let collected = await statuses(of: harness)

        guard case .failed(let reason) = collected.last else {
            Issue.record("expected .failed, got \(String(describing: collected.last))")
            return
        }
        #expect(reason.isEmpty == false)
        #expect(harness.client.quickConnectSignInCalls.isEmpty)
    }

    /// The secret was approved but the token exchange failed — the code is spent, so this is a
    /// plain failure, not an expiry the user can retry by re-approving.
    @Test("A failed token exchange after approval reports the mapped failure")
    func exchangeFailureAfterApproval() async throws {
        let harness = SessionManagerHarness()
        harness.client.quickConnectEventsToYield = [.success(.authenticated(secret: "secret-xyz"))]
        harness.client.quickConnectSignInResult = .failure(URLError(.timedOut))

        let collected = await statuses(of: harness)

        #expect(collected.last == .failed(reason: AppError.network(URLError(.timedOut)).userMessage))
        #expect(await harness.store.sessions.isEmpty)
    }

    @Test("A failed public-info fetch after approval reports the mapped failure")
    func publicInfoFailureAfterApproval() async throws {
        let harness = SessionManagerHarness()
        harness.client.quickConnectEventsToYield = [.success(.authenticated(secret: "secret-xyz"))]
        harness.client.quickConnectSignInResult = .success(SessionManagerHarness.authResult(accessToken: "tok-qc"))
        harness.client.publicSystemInfoResult = .failure(URLError(.cannotFindHost))

        let collected = await statuses(of: harness)

        #expect(collected.last == .failed(reason: AppError.network(URLError(.cannotFindHost)).userMessage))
        #expect(await harness.store.sessions.isEmpty)
    }

    /// Post-auth composition can still fail (a response with no server id). The stream must report
    /// it as a failure instead of yielding a half-built `.signedIn`.
    @Test("A post-auth composition failure reports a failure, not a session")
    func compositionFailureAfterApproval() async throws {
        let harness = SessionManagerHarness()
        harness.client.quickConnectEventsToYield = [.success(.authenticated(secret: "secret-xyz"))]
        harness.client.quickConnectSignInResult = .success(
            SessionManagerHarness.authResult(accessToken: "tok-qc", serverID: nil)
        )
        harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo(id: nil))

        let collected = await statuses(of: harness)

        guard case .failed = collected.last else {
            Issue.record("expected .failed, got \(String(describing: collected.last))")
            return
        }
        #expect(await harness.store.sessions.isEmpty)
    }
}

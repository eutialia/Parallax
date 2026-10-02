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

    /// The secret was approved but a later step failed. The code is spent, so each is a plain
    /// failure with its mapped reason, not an expiry the user can retry by re-approving. A
    /// composition failure (a response with no server id) must not yield a half-built `.signedIn`.
    @Test("A failure after approval reports the mapped failure, never a session", arguments: PostApprovalFailure.allCases)
    func failureAfterApproval(failure: PostApprovalFailure) async throws {
        let harness = SessionManagerHarness()
        harness.client.quickConnectEventsToYield = [.success(.authenticated(secret: "secret-xyz"))]
        switch failure {
        case .exchange:
            harness.client.quickConnectSignInResult = .failure(URLError(.timedOut))
        case .publicInfo:
            harness.client.quickConnectSignInResult = .success(SessionManagerHarness.authResult(accessToken: "tok-qc"))
            harness.client.publicSystemInfoResult = .failure(URLError(.cannotFindHost))
        case .composition:
            harness.client.quickConnectSignInResult = .success(
                SessionManagerHarness.authResult(accessToken: "tok-qc", serverID: nil)
            )
            harness.client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo(id: nil))
        }

        let collected = await statuses(of: harness)

        #expect(collected.last == .failed(reason: failure.expectedReason))
        #expect(await harness.store.sessions.isEmpty)
    }

    enum PostApprovalFailure: CaseIterable, Sendable {
        case exchange, publicInfo, composition

        var expectedReason: String {
            switch self {
            case .exchange: AppError.network(URLError(.timedOut)).userMessage
            case .publicInfo: AppError.network(URLError(.cannotFindHost)).userMessage
            case .composition: AppError.unexpected("", underlying: nil).userMessage
            }
        }
    }

    /// The auth client swallows its own cancellation and ends the event stream cleanly, so a run the
    /// user backed out of leaves the loop like a finished one, possibly holding an approved secret.
    /// It must stop there: exchanging the secret signs in to a server the user just walked away from.
    @Test("A cancelled run never exchanges an approved secret", .timeLimit(.minutes(1)))
    func cancelledRunNeverExchangesSecret() async throws {
        let (released, release) = AsyncStream.makeStream(of: [String].self)
        let storeHarness = JellyfinFixtures.serverStore("SessionManagerQuickConnectTests")
        let manager = SessionManager(
            serverStore: storeHarness.store,
            factory: HandOffClientFactory(Self.approvingClient { exchanged in
                release.yield(exchanged)
                release.finish()
            })
        )

        do {
            var statuses = await manager
                .signInWithQuickConnect(server: URL(string: "https://jellyfin.example.com")!)
                .makeAsyncIterator()
            #expect(await statuses.next() == .waitingForCode)
            // Queued behind the approval, so seeing it means the run already holds the secret.
            #expect(await statuses.next() == .polling(code: "AB12"))
        }
        // Dropping the status stream cancels the run; the client goes when the run ends.

        var exchanged: [String]?
        for await secrets in released { exchanged = secrets }
        #expect(exchanged == [])
        #expect(await storeHarness.store.sessions.isEmpty)
    }

    private static func approvingClient(
        onDeinit: @escaping @Sendable ([String]) -> Void
    ) -> FakeJellyfinAuthClient {
        let client = FakeJellyfinAuthClient()
        client.quickConnectEventsToYield = [
            .success(.authenticated(secret: "secret-xyz")),
            .success(.polling(code: "AB12")),
        ]
        client.quickConnectEventsStayOpen = true
        client.quickConnectSignInResult = .success(SessionManagerHarness.authResult(accessToken: "tok-qc"))
        client.publicSystemInfoResult = .success(SessionManagerHarness.publicInfo())
        client.onDeinit = onDeinit
        return client
    }
}

/// Hands its one client over and keeps no reference, so the client lives exactly as long as the
/// Quick Connect run that took it.
private final class HandOffClientFactory: JellyfinClientFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var client: FakeJellyfinAuthClient?

    init(_ client: FakeJellyfinAuthClient) {
        self.client = client
    }

    func make(serverURL: URL) async -> JellyfinAuthClient {
        lock.withLock {
            defer { client = nil }
            return client!
        }
    }
}

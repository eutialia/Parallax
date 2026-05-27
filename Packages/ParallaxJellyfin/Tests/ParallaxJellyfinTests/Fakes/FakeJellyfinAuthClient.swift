import Foundation
import JellyfinAPI
@testable import ParallaxJellyfin

final class FakeJellyfinAuthClient: JellyfinAuthClient, @unchecked Sendable {
    let serverURL: URL

    // Programmable hooks. Each Result is consumed once per call.
    var passwordSignInResult: Result<AuthenticationResult, Error> = .failure(FakeError.notConfigured)
    var quickConnectSignInResult: Result<AuthenticationResult, Error> = .failure(FakeError.notConfigured)
    var signOutResult: Result<Void, Error> = .success(())
    var publicSystemInfoResult: Result<PublicSystemInfo, Error> = .failure(FakeError.notConfigured)
    var quickConnectEventsToYield: [Result<QuickConnect.Event, Error>] = []

    // Call records for assertions.
    private(set) var passwordSignInCalls: [(username: String, password: String)] = []
    private(set) var quickConnectSignInCalls: [String] = []
    private(set) var signOutCalls: [String] = []
    private(set) var publicSystemInfoCallCount = 0
    private(set) var quickConnectEventStreamCount = 0

    enum FakeError: Error { case notConfigured }

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    func signIn(username: String, password: String) async throws -> AuthenticationResult {
        passwordSignInCalls.append((username, password))
        return try passwordSignInResult.get()
    }

    func signIn(quickConnectSecret: String) async throws -> AuthenticationResult {
        quickConnectSignInCalls.append(quickConnectSecret)
        return try quickConnectSignInResult.get()
    }

    func signOut(accessToken: String) async throws {
        signOutCalls.append(accessToken)
        try signOutResult.get()
    }

    func fetchPublicSystemInfo() async throws -> PublicSystemInfo {
        publicSystemInfoCallCount += 1
        return try publicSystemInfoResult.get()
    }

    func quickConnectEvents() -> AsyncThrowingStream<QuickConnect.Event, Error> {
        quickConnectEventStreamCount += 1
        let events = quickConnectEventsToYield
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    switch event {
                    case .success(let value):
                        continuation.yield(value)
                    case .failure(let error):
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
        }
    }
}

final class FakeJellyfinClientFactory: JellyfinClientFactory, @unchecked Sendable {
    private var clientsByURL: [URL: FakeJellyfinAuthClient] = [:]
    private(set) var makeCalls: [URL] = []

    func client(for url: URL) -> FakeJellyfinAuthClient {
        if let existing = clientsByURL[url] { return existing }
        let new = FakeJellyfinAuthClient(serverURL: url)
        clientsByURL[url] = new
        return new
    }

    func make(serverURL: URL) async -> JellyfinAuthClient {
        makeCalls.append(serverURL)
        return client(for: serverURL)
    }
}

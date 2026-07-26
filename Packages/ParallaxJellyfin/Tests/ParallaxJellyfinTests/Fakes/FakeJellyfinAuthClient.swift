import Foundation
import JellyfinAPI
@testable import ParallaxJellyfin

/// Every method body runs under `lock`: Quick Connect yields from a detached Task, so the stream
/// consumer and a test reading the call records can overlap.
final class FakeJellyfinAuthClient: JellyfinAuthClient, @unchecked Sendable {
    private let lock = NSLock()

    let serverURL: URL

    // Programmable hooks. Each Result is REPLAYED on every call, not consumed — a test can drive
    // the same method twice and get the same answer.
    var passwordSignInResult: Result<AuthenticationResult, Error> = .failure(FakeError.notConfigured)
    var quickConnectSignInResult: Result<AuthenticationResult, Error> = .failure(FakeError.notConfigured)
    var signOutResult: Result<Void, Error> = .success(())
    var publicSystemInfoResult: Result<PublicSystemInfo, Error> = .failure(FakeError.notConfigured)
    var quickConnectEventsToYield: [Result<QuickConnect.Event, Error>] = []

    // Call records for assertions.
    private var recordedPasswordSignInCalls: [(username: String, password: String)] = []
    private var recordedQuickConnectSignInCalls: [String] = []
    private var recordedSignOutCalls: [String] = []

    var passwordSignInCalls: [(username: String, password: String)] { lock.withLock { recordedPasswordSignInCalls } }
    var quickConnectSignInCalls: [String] { lock.withLock { recordedQuickConnectSignInCalls } }
    var signOutCalls: [String] { lock.withLock { recordedSignOutCalls } }

    enum FakeError: Error { case notConfigured }

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    func signIn(username: String, password: String) async throws -> AuthenticationResult {
        try lock.withLock {
            recordedPasswordSignInCalls.append((username, password))
            return try passwordSignInResult.get()
        }
    }

    func signIn(quickConnectSecret: String) async throws -> AuthenticationResult {
        try lock.withLock {
            recordedQuickConnectSignInCalls.append(quickConnectSecret)
            return try quickConnectSignInResult.get()
        }
    }

    func signOut(accessToken: String) async throws {
        try lock.withLock {
            recordedSignOutCalls.append(accessToken)
            try signOutResult.get()
        }
    }

    func fetchPublicSystemInfo() async throws -> PublicSystemInfo {
        try lock.withLock { try publicSystemInfoResult.get() }
    }

    func quickConnectEvents() -> AsyncThrowingStream<QuickConnect.Event, Error> {
        let events = lock.withLock { quickConnectEventsToYield }
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
    private let lock = NSLock()
    private var clientsByURL: [URL: FakeJellyfinAuthClient] = [:]

    /// One client per server URL, so a test programs the same instance the manager will use.
    func client(for url: URL) -> FakeJellyfinAuthClient {
        lock.withLock {
            if let existing = clientsByURL[url] { return existing }
            let new = FakeJellyfinAuthClient(serverURL: url)
            clientsByURL[url] = new
            return new
        }
    }

    func make(serverURL: URL) async -> JellyfinAuthClient {
        client(for: serverURL)
    }
}

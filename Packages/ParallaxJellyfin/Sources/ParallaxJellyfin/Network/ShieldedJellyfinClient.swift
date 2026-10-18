import Foundation
import Get
import JellyfinAPI
import os

/// The only door to jellyfin-sdk. Each call runs in a task the caller's cancellation never reaches;
/// a cancelled caller stops waiting with `CancellationError` and the request finishes unobserved.
///
/// Get 2.2.1, under the SDK, cancels the `URLSessionTask` before its `DataLoader` has registered it
/// when a request starts on an already-cancelled task. The completion then arrives for a task the
/// loader does not know, and `DataLoader.swift:96` traps. Get is unmaintained.
struct ShieldedJellyfinClient: Sendable {
    private let client: JellyfinClient

    init(_ client: JellyfinClient) {
        self.client = client
    }

    func send<T: Decodable & Sendable>(_ request: Request<T>) async throws -> Response<T> {
        try await shielded { [client] in try await client.send(request) }
    }

    @discardableResult
    func send(_ request: Request<Void>) async throws -> Response<Void> {
        try await shielded { [client] in try await client.send(request) }
    }

    func signIn(username: String, password: String) async throws -> AuthenticationResult {
        try await shielded { [client] in try await client.signIn(username: username, password: password) }
    }

    func signIn(quickConnectSecret: String) async throws -> AuthenticationResult {
        try await shielded { [client] in try await client.signIn(quickConnectSecret: quickConnectSecret) }
    }

    func signOut() async throws {
        try await shielded { [client] in try await client.signOut() }
    }

    func url(with request: Request<some Any>, queryAPIKey: Bool) -> URL? {
        client.url(with: request, queryAPIKey: queryAPIKey)
    }

    func url(path: String) -> URL? {
        client.url(path: path)
    }

    private func shielded<R: Sendable>(_ operation: @escaping @Sendable () async throws -> R) async throws -> R {
        let waiter = OSAllocatedUnfairLock<CheckedContinuation<R, any Error>?>(initialState: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.withLock { $0 = continuation }
                guard !Task.isCancelled else {
                    waiter.withLock { $0.take() }?.resume(throwing: CancellationError())
                    return
                }
                Task {
                    let result: Result<R, any Error>
                    do { result = .success(try await operation()) } catch { result = .failure(error) }
                    waiter.withLock { $0.take() }?.resume(with: result)
                }
            }
        } onCancel: {
            waiter.withLock { $0.take() }?.resume(throwing: CancellationError())
        }
    }
}

import Foundation
import JellyfinAPI
import ParallaxCore

public actor SessionManager {
    private let serverStore: ServerStore
    private let factory: JellyfinClientFactory

    public init(serverStore: ServerStore, factory: JellyfinClientFactory) {
        self.serverStore = serverStore
        self.factory = factory
    }

    public var current: Session? {
        get async { await serverStore.active }
    }

    public func signIn(server: URL, username: String, password: String) async throws -> Session {
        Log.network.info("signIn → \(server.absoluteString)")
        let client = await factory.make(serverURL: server)

        let authResult: AuthenticationResult
        do {
            authResult = try await client.signIn(username: username, password: password)
        } catch {
            Log.network.error("signIn authenticate failed: \(error.networkDiagnostic)")
            throw ErrorMapping.appError(from: error)
        }

        let publicInfo: PublicSystemInfo
        do {
            publicInfo = try await client.fetchPublicSystemInfo()
        } catch {
            Log.network.error("signIn publicInfo failed: \(error.networkDiagnostic)")
            throw ErrorMapping.appError(from: error)
        }

        let session = try buildSession(authResult: authResult, server: server, publicInfo: publicInfo)
        do {
            try await serverStore.add(session)
        } catch {
            Log.persistence.error("signIn ServerStore.add failed: \(error.networkDiagnostic)")
            throw AppError.unexpected(
                "ServerStore.add failed",
                underlying: AnySendableError(error)
            )
        }
        Log.auth.info("Signed in to \(publicInfo.serverName ?? "Jellyfin server") as \(session.user.name)")
        return session
    }

    /// Signs out remotely (best-effort — a 401 or offline state is fine, the
    /// local token revoke is what matters) and removes the session locally.
    /// Throws if the local removal cannot be persisted, so the UI can show
    /// the user that their "sign out" did not fully take effect.
    public func signOut(_ session: Session) async throws {
        Log.auth.info("signOut → \(session.serverName)")
        let client = await factory.make(serverURL: session.serverURL)
        do {
            try await client.signOut(accessToken: session.accessToken)
        } catch {
            // Type-only — don't pass the full mapped error description, which
            // could carry a request URL/header echoed back by the server.
            Log.auth.error("Remote sign-out failed for \(session.serverName) — \(String(describing: type(of: error)))")
        }
        do {
            try await serverStore.remove(session.id)
        } catch {
            Log.persistence.error("signOut ServerStore.remove failed: \(error.networkDiagnostic)")
            throw AppError.unexpected(
                "ServerStore.remove failed",
                underlying: AnySendableError(error)
            )
        }
    }

    public func signInWithQuickConnect(server: URL) -> AsyncStream<QuickConnectStatus> {
        AsyncStream { continuation in
            let task = Task {
                await runQuickConnect(server: server, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runQuickConnect(
        server: URL,
        continuation: AsyncStream<QuickConnectStatus>.Continuation
    ) async {
        Log.network.info("quickConnect → \(server.absoluteString)")
        continuation.yield(.waitingForCode)
        let client = await factory.make(serverURL: server)
        let events = client.quickConnectEvents()

        var secret: String?
        do {
            for try await event in events {
                switch event {
                case .polling(let code):
                    continuation.yield(.polling(code: code))
                case .authenticated(let s):
                    secret = s
                }
            }
        } catch is CancellationError {
            continuation.finish()
            return
        } catch {
            Log.network.error("quickConnect stream failed: \(error.networkDiagnostic)")
            let mapped = ErrorMapping.appError(from: error)
            if case .auth(.quickConnectExpired) = mapped {
                continuation.yield(.expired)
            } else {
                continuation.yield(.failed(reason: mapped.userMessage))
            }
            continuation.finish()
            return
        }

        // The SDK's QuickConnect.connect() swallows CancellationError and just
        // finish()es the stream — so a cancelled run reaches here with the
        // for-await loop having exited cleanly and `secret == nil`. Check the
        // cancellation flag before treating that as a real failure.
        if Task.isCancelled {
            continuation.finish()
            return
        }

        guard let secret else {
            continuation.yield(.failed(reason: "Your server ended Quick Connect without approving this device."))
            continuation.finish()
            return
        }

        let auth: AuthenticationResult
        do {
            auth = try await client.signIn(quickConnectSecret: secret)
        } catch {
            Log.network.error("quickConnect authenticate failed: \(error.networkDiagnostic)")
            continuation.yield(.failed(reason: ErrorMapping.appError(from: error).userMessage))
            continuation.finish()
            return
        }

        let info: PublicSystemInfo
        do {
            info = try await client.fetchPublicSystemInfo()
        } catch {
            Log.network.error("quickConnect publicInfo failed: \(error.networkDiagnostic)")
            continuation.yield(.failed(reason: ErrorMapping.appError(from: error).userMessage))
            continuation.finish()
            return
        }

        do {
            let session = try buildSession(authResult: auth, server: server, publicInfo: info)
            try await serverStore.add(session)
            Log.auth.info("Signed in via Quick Connect to \(info.serverName ?? "Jellyfin server") as \(session.user.name)")
            continuation.yield(.signedIn(session))
        } catch {
            Log.auth.error("Quick Connect post-auth failed: \(String(describing: type(of: error)))")
            continuation.yield(.failed(reason: ErrorMapping.appError(from: error).userMessage))
        }
        continuation.finish()
    }

    // Internal — accessible from the same target.
    func buildSession(authResult: AuthenticationResult, server: URL, publicInfo: PublicSystemInfo) throws -> Session {
        guard let accessToken = authResult.accessToken else {
            throw AppError.auth(.invalidCredentials)
        }
        guard let user = authResult.user, let userID = user.id, let userName = user.name else {
            throw AppError.unexpected("Jellyfin auth: missing user in response", underlying: nil)
        }
        let serverID: String
        if let fromAuth = authResult.serverID {
            serverID = fromAuth
        } else if let fromInfo = publicInfo.id {
            serverID = fromInfo
        } else {
            throw AppError.unexpected("Jellyfin auth: missing serverID in response", underlying: nil)
        }
        let serverName = publicInfo.serverName ?? server.host ?? "Jellyfin"

        let persisted = PersistedSession(
            id: ServerID(rawValue: serverID),
            serverURL: server,
            serverName: serverName,
            user: UserSnapshot(
                id: userID,
                name: userName,
                serverLastUpdatedAt: user.lastActivityDate
            )
        )
        return Session(persisted: persisted, accessToken: accessToken)
    }
}

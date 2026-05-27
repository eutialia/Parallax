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
        let client = await factory.make(serverURL: server)

        let authResult: AuthenticationResult
        do {
            authResult = try await client.signIn(username: username, password: password)
        } catch {
            throw ErrorMapping.appError(from: error)
        }

        let publicInfo: PublicSystemInfo
        do {
            publicInfo = try await client.fetchPublicSystemInfo()
        } catch {
            throw ErrorMapping.appError(from: error)
        }

        let session = try buildSession(authResult: authResult, server: server, publicInfo: publicInfo)
        do {
            try await serverStore.add(session)
        } catch {
            throw AppError.unexpected(
                "ServerStore.add failed",
                underlying: AnySendableError(error)
            )
        }
        Log.auth.info("Signed in to \(publicInfo.serverName ?? "Jellyfin server") as \(session.user.name)")
        return session
    }

    public func signOut(_ session: Session) async {
        let client = await factory.make(serverURL: session.serverURL)
        do {
            try await client.signOut(accessToken: session.accessToken)
        } catch {
            Log.auth.error("Remote sign-out failed for \(session.serverName) — \(ErrorMapping.appError(from: error).diagnosticDescription)")
            // Continue: local removal is the security-relevant action.
        }
        do {
            try await serverStore.remove(session.id)
        } catch {
            Log.persistence.error("ServerStore.remove failed for \(session.id.rawValue) — \(error.localizedDescription)")
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
        } catch {
            let mapped = ErrorMapping.appError(from: error)
            if case .auth(.quickConnectExpired) = mapped {
                continuation.yield(.expired)
            } else {
                continuation.yield(.rejected)
            }
            continuation.finish()
            return
        }

        guard let secret else {
            continuation.yield(.rejected)
            continuation.finish()
            return
        }

        let auth: AuthenticationResult
        do {
            auth = try await client.signIn(quickConnectSecret: secret)
        } catch {
            continuation.yield(.rejected)
            continuation.finish()
            return
        }

        let info: PublicSystemInfo
        do {
            info = try await client.fetchPublicSystemInfo()
        } catch {
            continuation.yield(.rejected)
            continuation.finish()
            return
        }

        do {
            let session = try buildSession(authResult: auth, server: server, publicInfo: info)
            try await serverStore.add(session)
            continuation.yield(.signedIn(session))
        } catch {
            Log.auth.error("Quick Connect post-auth failed: \(ErrorMapping.appError(from: error).diagnosticDescription)")
            continuation.yield(.rejected)
        }
        continuation.finish()
    }

    // Internal — accessible from the same target (Task 9 Quick Connect will call this).
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
            user: UserSnapshot(id: userID, name: userName, serverLastUpdatedAt: user.lastActivityDate)
        )
        return Session(persisted: persisted, accessToken: accessToken)
    }
}

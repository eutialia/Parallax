import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class ServerListViewModel {
    var sessions: [Session] = []
    var activeID: ServerID?
    var presentingAddServer: Bool = false
    /// Surfaces the most recent sign-out failure so the UI can show the user
    /// that their action did not fully take effect. Cleared on next refresh().
    var signOutErrorMessage: String?

    private let sessionManager: SessionManager
    private let serverStore: ServerStore
    private let router: AppRouter

    init(sessionManager: SessionManager, serverStore: ServerStore, router: AppRouter) {
        self.sessionManager = sessionManager
        self.serverStore = serverStore
        self.router = router
    }

    func refresh() async {
        sessions = await serverStore.sessions
        activeID = await serverStore.active?.id
        signOutErrorMessage = nil
    }

    func setActive(_ id: ServerID) async {
        do {
            try await serverStore.setActive(id)
        } catch {
            Log.persistence.error("ServerList setActive failed for \(id.rawValue): \(error.networkDiagnostic)")
        }
        await refresh()
    }

    func signOut(_ session: Session) async {
        do {
            try await sessionManager.signOut(session)
        } catch let error as AppError {
            Log.auth.error("ServerList signOut failed for \(session.serverName): \(error.userMessage)")
            signOutErrorMessage = "Couldn't fully sign out of \(session.serverName): \(error.userMessage)"
        } catch {
            Log.auth.error("ServerList signOut unexpected for \(session.serverName): \(String(describing: type(of: error)))")
            signOutErrorMessage = "Couldn't fully sign out of \(session.serverName)."
        }
        await refresh()
        if sessions.isEmpty {
            router.goToLogin()
        }
    }

    func presentAddServer() {
        presentingAddServer = true
    }

    func dismissAddServer() async {
        presentingAddServer = false
        await refresh()
    }
}

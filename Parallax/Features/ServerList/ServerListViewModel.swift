import Foundation
import Observation
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
        try? await serverStore.setActive(id)
        await refresh()
    }

    func signOut(_ session: Session) async {
        do {
            try await sessionManager.signOut(session)
        } catch let error as AppError {
            signOutErrorMessage = "Couldn't fully sign out of \(session.serverName): \(error.userMessage)"
        } catch {
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

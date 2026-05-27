import Foundation
import Observation
import ParallaxJellyfin

@Observable
@MainActor
final class ServerListViewModel {
    var sessions: [Session] = []
    var activeID: ServerID?
    var presentingAddServer: Bool = false

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
    }

    func setActive(_ id: ServerID) async {
        try? await serverStore.setActive(id)
        await refresh()
    }

    func signOut(_ session: Session) async {
        await sessionManager.signOut(session)
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

import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class SettingsViewModel {
    var sessions: [Session] = []
    var smbServers: [PersistedServer] = []
    var activeID: ServerID?
    /// Surfaces the most recent sign-out failure so the UI can show the user that their
    /// action did not fully take effect. Set at the start of `signOut` (cleared) and only
    /// on failure — `refresh()` deliberately leaves it alone so the message survives the
    /// post-action reload (a fresh panel open builds a new view model, so it never leaks).
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
        smbServers = await serverStore.servers.filter {
            if case .smb = $0.kind { return true }
            return false
        }
    }

    func removeSMBServer(_ id: ServerID) async {
        do {
            try await serverStore.remove(id)
        } catch {
            Log.persistence.error("Settings removeSMBServer failed for \(id.rawValue): \(error.localizedDescription)")
        }
        await reloadAfterSMBChange()
    }

    /// Reload the settings list AND bump the router's library revision, so the navigation
    /// roots rebuild their merged library list immediately after an SMB server is added or
    /// removed. The active Jellyfin session is unchanged by an SMB change, so `activeServerID`
    /// doesn't move — the revision bump is what re-fires the roots' library `.task`.
    func reloadAfterSMBChange() async {
        await refresh()
        router.bumpLibraryRevision()
    }

    func setActive(_ id: ServerID) async {
        do {
            try await serverStore.setActive(id)
        } catch {
            Log.persistence.error("Settings setActive failed for \(id.rawValue): \(error.networkDiagnostic)")
        }
        await syncRouterToActive()
    }

    func signOut(_ session: Session) async {
        signOutErrorMessage = nil
        do {
            try await sessionManager.signOut(session)
        } catch let error as AppError {
            Log.auth.error("Settings signOut failed for \(session.serverName): \(error.userMessage)")
            signOutErrorMessage = "Couldn't fully sign out of \(session.serverName): \(error.userMessage)"
        } catch {
            Log.auth.error("Settings signOut unexpected for \(session.serverName): \(String(describing: type(of: error)))")
            signOutErrorMessage = "Couldn't fully sign out of \(session.serverName). Try again."
        }
        await syncRouterToActive()
    }

    /// Called after the add-server flow signs in. A newly added server may have become
    /// active, so re-point the router to remount the tabs onto it.
    func didAddServer() async {
        await syncRouterToActive()
    }

    /// Reload the list, then point the router at whatever is active now: nil (no sessions
    /// left) routes to login; otherwise the store's fallback active server, with a tab
    /// remount so the screens leave the previous server's content. The active session is
    /// taken from the freshly-loaded `sessions` rather than re-querying the store, so the
    /// router and the list can't disagree (and it saves a second actor hop).
    private func syncRouterToActive() async {
        await refresh()
        router.updateForCurrentSession(sessions.first { $0.id == activeID })
    }
}

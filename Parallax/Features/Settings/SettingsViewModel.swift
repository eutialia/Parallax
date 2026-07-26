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
    /// Jellyfin servers whose persisted row survives but whose Keychain token was lost (bundle-id/
    /// access-group change, device migration) — rendered as signed-out rows so they never ghost
    /// invisibly; re-signing-in heals them in place, removal discards them.
    var signedOutServers: [PersistedServer] = []
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
        smbServers = await serverStore.servers.filter {
            if case .smb = $0.kind { return true }
            return false
        }
        signedOutServers = await serverStore.signedOutJellyfinServers
    }

    /// Discards a signed-out Jellyfin row. No router sync needed: a signed-out server had no
    /// session, so removing it can't move the active session or cross the login/home boundary.
    func removeSignedOutServer(_ id: ServerID) async {
        do {
            try await serverStore.remove(id)
        } catch {
            Log.persistence.error("Settings removeSignedOutServer failed for \(id.rawValue): \(error.localizedDescription)")
        }
        await refresh()
    }

    func removeSMBServer(_ id: ServerID) async {
        do {
            try await serverStore.remove(id)
        } catch {
            Log.persistence.error("Settings removeSMBServer failed for \(id.rawValue): \(error.localizedDescription)")
        }
        await reloadAfterSMBChange()
    }

    /// Reload the settings list and re-point the router after an SMB server is added or removed.
    /// The roots' library rebuild needs no explicit revision bump: adding or removing a server
    /// changes `SourceSnapshot.setIdentity`, which is part of their reload token. (A change to an
    /// existing server's SELECTED SHARES does still bump — the source set is unchanged there, so no
    /// fingerprint can see it; that's `SMBServerSettingsView`'s job.) Routing is re-run because an
    /// SMB change can cross the login/home boundary for an SMB-only config: adding the first source
    /// unblocks home, removing the last strands an empty config that must fall back to login.
    func reloadAfterSMBChange() async {
        await refresh()
        router.updateForSources(await serverStore.sourceSnapshot)
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
        await syncRouterToSources()
    }

    /// Called after the add-server flow signs in. The new server may have become active (first
    /// sign-in) or may not (a SECOND Jellyfin server leaves the first active) — either way the
    /// source set changed, and `syncRouterToSources` carries both cases.
    func didAddServer() async {
        await syncRouterToSources()
    }

    /// Reload the list, then hand the router one fresh read of the whole source configuration: no
    /// Jellyfin session left routes to login UNLESS an SMB source remains (then SMB-only home);
    /// otherwise the store's fallback active server, with a tab remount so the screens leave the
    /// previous server's content.
    ///
    /// The snapshot is read from the store rather than assembled from this view model's local
    /// `sessions`/`smbServers`: those describe what the LIST shows, and reconstructing the router's
    /// input from them is what let the two disagree. Adding a second Jellyfin server changed
    /// neither the active session nor SMB presence, so the reconstructed value was identical to the
    /// previous one and the roots never rebuilt — the new server's libraries stayed missing until
    /// the next launch. `setIdentity` inside the snapshot is what makes that case visible.
    private func syncRouterToSources() async {
        await refresh()
        router.updateForSources(await serverStore.sourceSnapshot)
    }
}

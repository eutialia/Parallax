import Foundation
import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// Re-entering the password for an SMB server that is ALREADY configured, behind
/// `SMBPasswordRecoveryView` — the SMB twin of Jellyfin's "Sign In Again".
///
/// Verification runs BEFORE anything is written: the typed password is used to enumerate the
/// server's shares (the same `listShares()` probe the add-server form validates with), and only a
/// success reaches `ServerStore.updateSMBPassword`. A refusal keeps the user in the form with the
/// reason, so a typo never overwrites a password that might still be right.
@Observable
@MainActor
public final class SMBPasswordRecoveryModel {
    public let data: SMBServerData
    public var password = ""
    public private(set) var errorMessage: String?
    public private(set) var isVerifying = false

    private let id: ServerID
    private let makeLister: @Sendable (SMBCredentials) -> any SMBLister
    private let serverStore: ServerStore
    private let clock: any Clock<Duration>
    /// Called after the new password verified and was stored — the host reloads whatever it was
    /// doing (the share list, the browse level) and pops the form.
    private let onRecovered: () -> Void

    /// The in-flight verification. Held so Cancel / leaving the screen can drop it — the same
    /// reason `SMBAddServerModel` holds its connect task: a dead host wedges the attempt otherwise.
    private var verifyTask: Task<Void, Never>?
    /// Failsafe over the whole attempt, above every layer this model awaits (the lister hard-bounds
    /// its own calls, and device runs still wedged — see `SMBAddServerModel`).
    private var watchdogTask: Task<Void, Never>?

    init(
        id: ServerID,
        data: SMBServerData,
        makeLister: @escaping @Sendable (SMBCredentials) -> any SMBLister,
        serverStore: ServerStore,
        clock: any Clock<Duration>,
        onRecovered: @escaping () -> Void
    ) {
        self.id = id
        self.data = data
        self.makeLister = makeLister
        self.serverStore = serverStore
        self.clock = clock
        self.onRecovered = onRecovered
    }

    public func submit() {
        // The keyboard's return key routes here unconditionally (`submitChain`), so it can fire
        // while a verify is already in flight.
        guard !isVerifying else { return }
        errorMessage = nil
        isVerifying = true
        let (candidate, serverID, host, makeLister, store) = (password, id, data.host, makeLister, serverStore)

        verifyTask?.cancel()
        verifyTask = Task {
            do {
                // The store owns the ordering: it resolves the persisted server, runs this probe,
                // and writes the Keychain only if the probe returns.
                try await store.updateSMBPassword(candidate, for: serverID) { server, password in
                    _ = try await makeLister(SMBCredentials(
                        host: server.host, username: server.username, password: password, domain: server.domain
                    )).listShares()
                }
                guard !Task.isCancelled else { return }
                isVerifying = false
                watchdogTask?.cancel()
                onRecovered()
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = Self.message(for: error, host: host)
            }
            isVerifying = false
            watchdogTask?.cancel()
        }

        watchdogTask?.cancel()
        watchdogTask = Task { [clock] in
            try? await clock.sleep(for: .seconds(30))
            guard !Task.isCancelled, isVerifying else { return }
            verifyTask?.cancel()
            verifyTask = nil
            isVerifying = false
            errorMessage = "Timed out. Check that \(host) is on and try again."
        }
    }

    public func cancel() {
        verifyTask?.cancel()
        verifyTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        isVerifying = false
    }

    /// Inline failure copy. A refused sign-in is the expected one (that's why the user is here), so
    /// it reads as "that password didn't work" rather than a connectivity story. Everything that is
    /// NOT the password's fault must say so: a share-ACL denial (EACCES — the credentials are fine,
    /// the account is locked out of enumeration), a local save failure after a successful probe, a
    /// server removed while the form was open. Blaming those on the password sends the user in
    /// circles re-typing a correct secret. Never echoes it.
    static func message(for error: Error, host: String) -> String {
        if let storeError = error as? ServerStore.ServerStoreError {
            switch storeError {
            case .notAnSMBServer:
                return "This server is no longer set up. Add it again from Settings."
            case .persistenceFailed, .decodeFailed:
                return "The password checked out, but it couldn't be saved. Try again."
            }
        }
        let appError = (error as? AppError) ?? SMBFileSource.mapShareListError(error, host: host)
        switch appError {
        case .auth:
            return "\(host) rejected that password. Check it and try again."
        case .source(.permissionDenied):
            return "\(host) accepted the sign-in but denied access for this account. The password may be right — check the account's permissions on the server."
        default:
            return "Couldn't reach \(host). Check that it's on, then try again."
        }
    }
}

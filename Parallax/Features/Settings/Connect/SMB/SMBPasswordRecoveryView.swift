import SwiftUI
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// Re-enter the password for an SMB server that is ALREADY configured — the SMB twin of Jellyfin's
/// "Sign In Again". Reached from the two places a saved password stops working: the Settings share
/// list and the browse wall's share-root failure.
///
/// Deliberately a single field. The row already knows the host, the account, the domain and the
/// selected shares (all persisted); only the secret is missing, so asking for anything else would be
/// asking the user to re-type what the screen is showing them. The server identity renders read-only
/// above the field for context, in the same grouped-card idiom as `SMBLoginView`'s form.
///
/// Verification runs BEFORE anything is written: the typed password is used to enumerate the
/// server's shares (the same `listShares()` probe the add-server form validates with), and only a
/// success reaches `ServerStore.updateSMBPassword`. A refusal keeps the user in the form with the
/// reason, so a typo never overwrites a password that might still be right.
struct SMBPasswordRecoveryView: View {
    let id: ServerID
    let data: SMBServerData
    /// Called after the new password verified and was stored — the host reloads whatever it was
    /// doing (the share list, the browse level) and pops this screen.
    var onRecovered: () -> Void

    @Environment(AppDependencies.self) private var deps

    @State private var password = ""
    #if !os(tvOS)
    @State private var showPassword = false
    /// Single-field chain: return is "go" and submits (see `submitChain`).
    @FocusState private var focusedField: Field?
    private enum Field: CaseIterable { case password }
    #endif

    @State private var errorMessage: String?
    /// The in-flight verification. Held so Cancel / leaving the screen can drop it — the same
    /// reason `SMBLoginView` holds its connect task: a dead host wedges the attempt otherwise.
    @State private var verifyTask: Task<Void, Never>?
    /// UI-level failsafe over the whole attempt, above every layer this view awaits (the lister
    /// hard-bounds its own calls, and device runs still wedged — see `SMBLoginView`).
    @State private var watchdogTask: Task<Void, Never>?
    @State private var isVerifying = false
    /// Incremented on submit; `CredentialRowList` resigns any stale tvOS hidden-field first
    /// responder when it moves.
    @State private var fieldSweep = 0

    private var host: String { data.host }

    private var account: String { data.username.isEmpty ? "Guest" : data.username }

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            VStack(spacing: Space.s18) {
                #if os(tvOS)
                // tvOS has no nav bar (the native pill only reads "Settings"), so the form carries
                // its own identity inline — same rule as the add-server form.
                FormIntroHeader(
                    glyph: .symbol("key"),
                    title: "Enter Password",
                    subtitle: "Parallax couldn’t use the saved password for this server."
                )
                .padding(.bottom, Space.s8)
                #endif

                SettingsGroup(title: "Server") {
                    SettingsRowLabel(
                        systemImage: "externaldrive.badge.wifi",
                        title: "Address",
                        value: "smb://\(host)"
                    )
                    SettingsRowLabel(systemImage: "person", title: "Account", value: account)
                }

                passwordSection

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.headerInset)
                }

                submitButton
            }
        }
        .navigationTitle("Enter Password")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Full reset, not a bare cancel: a cancelled task's early returns skip the epilogue, which
        // would leave the spinner latched if the screen were re-entered.
        .onDisappear { cancelVerify() }
    }

    // MARK: - Field

    /// tvOS uses the Settings-style row list (row → single-field keyboard screen); iOS keeps the
    /// inline grouped field. Same split as `SMBLoginView`.
    @ViewBuilder
    private var passwordSection: some View {
        #if os(tvOS)
        CredentialRowList(
            rows: [
                CredentialRow(
                    id: "password",
                    title: "Password",
                    placeholder: "Optional",
                    text: $password,
                    isSecure: true
                ),
            ],
            sweepToken: fieldSweep
        )
        #else
        SettingsGroup(title: "Password", footer: "Leave blank to connect as a guest.") {
            CredentialFieldRow(icon: "lock") {
                HStack {
                    Group {
                        if showPassword { TextField("Password", text: $password) }
                        else { SecureField("Password", text: $password) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitChain(.password, focus: $focusedField, onComplete: submit)
                    PasswordRevealToggle(isRevealed: $showPassword)
                }
            }
        }
        #endif
    }

    // MARK: - Submit button

    /// ONE button that morphs Save ⇄ Cancel, never a disabled button plus an inserted one: on tvOS
    /// disabling the focused control strands the focus engine (see `SMBLoginView.connectButton`).
    private var submitButton: some View {
        Button {
            if isVerifying { cancelVerify() } else { submit() }
        } label: {
            Text(isVerifying ? "Cancel" : "Save Password")
                .formActionLabel(isWorking: isVerifying)
        }
        .formActionButton(.solid)
    }

    // MARK: - Verify + store

    private func submit() {
        // The keyboard's return key routes here unconditionally (`submitChain`), so it can fire
        // while a verify is already in flight — same guard idiom as `SMBLoginView.handleSubmit`.
        guard !isVerifying else { return }
        errorMessage = nil
        isVerifying = true
        // Release any hidden tvOS credential field still holding first responder.
        fieldSweep += 1

        // Capture everything the escaping task needs, so nothing inside it reads view state.
        let candidate = password
        let serverID = id
        let makeLister = deps.makeSMBListerForCredentials
        let store = deps.serverStore

        verifyTask?.cancel()
        verifyTask = Task {
            do {
                // The store owns the ordering: it resolves the persisted server, runs this probe,
                // and writes the Keychain only if the probe returns.
                try await store.updateSMBPassword(candidate, for: serverID) { server, password in
                    let lister = makeLister(
                        SMBCredentials(
                            host: server.host,
                            username: server.username,
                            password: password,
                            domain: server.domain
                        )
                    )
                    _ = try await lister.listShares()
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
        watchdogTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, isVerifying else { return }
            verifyTask?.cancel()
            verifyTask = nil
            isVerifying = false
            errorMessage = "Timed out. Check that \(host) is on and try again."
        }
    }

    private func cancelVerify() {
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
    /// circles re-typing a correct secret. Never echoes it. Static + pure so the mapping is
    /// testable without standing up the view.
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

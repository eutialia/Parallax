import SwiftUI
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxFeatures

/// Re-enter the password for an SMB server that is ALREADY configured — the SMB twin of Jellyfin's
/// "Sign In Again". Reached from the two places a saved password stops working: the Settings share
/// list and the browse wall's share-root failure.
///
/// Deliberately a single field. The row already knows the host, the account, the domain and the
/// selected shares (all persisted); only the secret is missing, so asking for anything else would be
/// asking the user to re-type what the screen is showing them. The server identity renders read-only
/// above the field for context, in the same grouped-card idiom as `SMBLoginView`'s form.
///
/// Verification runs before anything is written; see `SMBPasswordRecoveryModel`.
struct SMBPasswordRecoveryView: View {
    @State private var model: SMBPasswordRecoveryModel
    #if !os(tvOS)
    @State private var showPassword = false
    /// Single-field chain: return is "go" and submits (see `submitChain`).
    @FocusState private var focusedField: Field?
    private enum Field: CaseIterable { case password }
    #endif

    private var host: String { model.data.host }

    private var account: String { model.data.username.isEmpty ? "Guest" : model.data.username }

    /// `onRecovered` runs after the new password verified and was stored — the host reloads
    /// whatever it was doing (the share list, the browse level) and pops this screen.
    init(app: AppModel, id: ServerID, data: SMBServerData, onRecovered: @escaping () -> Void) {
        _model = State(initialValue: app.makeSMBPasswordRecovery(id: id, data: data, onRecovered: onRecovered))
    }

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

                if let errorMessage = model.errorMessage {
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
        .onDisappear { model.cancel() }
    }

    // MARK: - Field

    /// tvOS uses the Settings-style row list (row → single-field keyboard screen); iOS keeps the
    /// inline grouped field. Same split as `SMBLoginView`.
    @ViewBuilder
    private var passwordSection: some View {
        @Bindable var model = model
        #if os(tvOS)
        CredentialRowList(
            rows: [
                CredentialRow(
                    id: "password",
                    title: "Password",
                    placeholder: "Optional",
                    text: $model.password,
                    isSecure: true
                ),
            ]
        )
        #else
        SettingsGroup(title: "Password", footer: "Leave blank to connect as a guest.") {
            CredentialFieldRow(icon: "lock") {
                HStack {
                    Group {
                        if showPassword { TextField("Password", text: $model.password) }
                        else { SecureField("Password", text: $model.password) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitChain(.password, focus: $focusedField) { model.submit() }
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
            if model.isVerifying { model.cancel() } else { model.submit() }
        } label: {
            Text(model.isVerifying ? "Cancel" : "Save Password")
                .formActionLabel(isWorking: model.isVerifying)
        }
        .formActionButton(.solid)
    }
}

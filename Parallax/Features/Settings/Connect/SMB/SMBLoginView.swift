import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxFeatures

/// Add-SMB-server form: collects host + credentials, validates the connection by
/// enumerating shares, then hands off to `SMBShareSelectionView` to let the user
/// choose which shares to mount as libraries.
///
/// Discovery lifecycle mirrors `LoginView`: `SMBAddServerModel.discoverServers()` runs for as
/// long as the form is up, `#if !os(tvOS)` gated because tvOS has no mDNS LAN discovery
/// prompt and the Bonjour browser is unconditional (no permission gate — safe to run on
/// tvOS too, but the picker rows are irrelevant on the 10-foot UI).
struct SMBLoginView: View {
    /// Called after a server is successfully saved (shares selected + stored in Keychain).
    var onAdded: () -> Void

    @Environment(AppModel.self) private var app

    /// The add-server flow, shared with the pushed share picker.
    @State private var model: SMBAddServerModel?
    #if !os(tvOS)
    @State private var showPassword = false
    #endif

    #if !os(tvOS)
    /// Return-key field walk: return advances to the next field, "go" on the last (password) connects.
    /// `allCases` order is the field sequence `submitChain` reads.
    @FocusState private var focusedField: Field?
    private enum Field: CaseIterable { case host, username, password }
    #endif

    var body: some View {
        Group {
            if let model { form(model: model) }
        }
        .task {
            if model == nil { model = app.makeSMBAddServer() }
        }
    }

    @ViewBuilder
    private func form(model: SMBAddServerModel) -> some View {
        @Bindable var model = model
        SettingsScaffold(showsBrand: false) {
            VStack(spacing: Space.s18) {
                #if os(tvOS)
                // tvOS has no nav bar (the native pill only reads "Settings"), so the form carries its
                // own identity inline (handoff `.fhead`). iOS shows the "Network Share" nav title instead.
                FormIntroHeader(
                    glyph: .symbol("externaldrive.badge.wifi"),
                    title: "Network Share",
                    subtitle: "Connect over SMB. Leave the account blank to join as a guest."
                )
                .padding(.bottom, Space.s8)
                #endif

                #if !os(tvOS)
                discoveredServersSection(model: model)
                #endif

                fieldsSection(model: model)

                if let error = model.connectionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.headerInset)
                }

                connectButton(model: model)
            }
        }
        #if !os(tvOS)
        .task { await model.discoverServers() }
        #endif
        // Tear down any in-flight connection test when leaving the form (Menu/Back, or a tab
        // switch away) — a full reset, not just task cancellation: a cancelled task's early
        // returns skip the epilogue, and a bare cancel left `isConnecting` latched, so switching
        // tabs mid-connect and back showed a stale Cancel+spinner with no live task behind it.
        .onDisappear { model.cancelConnect() }
        .navigationDestination(isPresented: $model.showShareSelector) {
            SMBShareSelectionView(model: model, onAdded: onAdded)
                .tvHidesTabSidebar()
        }
    }

    // MARK: - Discovered servers

    #if !os(tvOS)
    @ViewBuilder
    private func discoveredServersSection(model: SMBAddServerModel) -> some View {
        if !model.discoveredServers.isEmpty {
            SettingsGroup(title: "Discovered") {
                ForEach(model.discoveredServers) { server in
                    SettingsListRow(
                        systemImage: "network",
                        title: server.name,
                        subtitle: server.host
                    ) {
                        model.host = server.host
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Fields

    /// tvOS uses the Settings-style row list (rows → single-field keyboard screen, no inline field
    /// pill); iOS keeps the inline grouped fields. See `CredentialRowList` for why.
    @ViewBuilder
    private func fieldsSection(model: SMBAddServerModel) -> some View {
        #if os(tvOS)
        // No last-field auto-connect: tvOS's system keyboard Done returns to the form, and the
        // always-present Connect button submits (gated to a complete form).
        CredentialRowList(rows: credentialRows(model: model))
        #else
        connectionFieldsSection(model: model)
        #endif
    }

    #if os(tvOS)
    private func credentialRows(model: SMBAddServerModel) -> [CredentialRow] {
        @Bindable var model = model
        return [
            CredentialRow(id: "host", title: "Server", placeholder: "e.g. 192.168.1.10", text: $model.host, keyboard: .URL),
            CredentialRow(id: "username", title: "Username", placeholder: "Optional", text: $model.username),
            CredentialRow(id: "password", title: "Password", placeholder: "Optional", text: $model.password, isSecure: true),
        ]
    }
    #endif

    #if !os(tvOS)
    private func connectionFieldsSection(model: SMBAddServerModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: Space.s18) {
            SettingsGroup(title: "Server") {
                CredentialFieldRow(icon: "externaldrive.badge.wifi") {
                    HStack(spacing: 0) {
                        Text("smb://").foregroundStyle(Color.tertiaryLabel)
                        // Placeholder must read as an OBVIOUS example: a plausible real-looking
                        // hostname here ("mynas.local") was mistaken for a LAN-discovered value.
                        TextField("mynas.local", text: $model.host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitChain(.host, focus: $focusedField) { handleSubmit(model: model) }
                    }
                }
            }
            SettingsGroup(title: "Sign In", footer: "Leave blank to connect as a guest.") {
                CredentialFieldRow(icon: "person") {
                    TextField("Username", text: $model.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitChain(.username, focus: $focusedField) { handleSubmit(model: model) }
                }
                CredentialFieldRow(icon: "lock") {
                    HStack {
                        Group {
                            if showPassword { TextField("Password", text: $model.password) }
                            else { SecureField("Password", text: $model.password) }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitChain(.password, focus: $focusedField) { handleSubmit(model: model) }
                        PasswordRevealToggle(isRevealed: $showPassword)
                    }
                }
            }
        }
    }

    /// "Go" on the last field connects, but only when the host is filled — the same
    /// gate the Connect button enforces, so return on an incomplete form is a no-op.
    private func handleSubmit(model: SMBAddServerModel) {
        guard model.canConnect else { return }
        model.connect()
    }
    #endif

    // MARK: - Connect button

    /// ONE button that MORPHS Connect ⇄ Cancel — never a disabled Connect plus a separately-inserted
    /// Cancel. On tvOS, disabling the *focused* control strands the focus engine: focus has nowhere to
    /// land (the just-appeared Cancel doesn't receive it), so the D-pad goes dead and Menu can't pop —
    /// the reported freeze. Keeping a single button with a STABLE identity means focus never moves: it
    /// stays focusable while connecting and tapping it cancels, so there's always a live focus target
    /// and a way out. While working, `formActionLabel` keeps the "Cancel" title VISIBLE beside the
    /// spinner — hidden, the in-flight button read as a frozen blank pill on Apple TV.
    private func connectButton(model: SMBAddServerModel) -> some View {
        Button {
            if model.isConnecting { model.cancelConnect() } else { model.connect() }
        } label: {
            Text(model.isConnecting ? "Cancel" : "Connect")
                .formActionLabel(isWorking: model.isConnecting)
        }
        .formActionButton(.solid)
        // Disabled ONLY when idle with an incomplete form — never while connecting, or focus is
        // stranded the instant the button would shed focus.
        .disabled(!model.isConnecting && !model.canConnect)
    }
}

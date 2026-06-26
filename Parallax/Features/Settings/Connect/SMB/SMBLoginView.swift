import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin

/// Add-SMB-server form: collects host / share / credentials, validates the connection by
/// doing a real `list(share:path:"")`, then hands off to `SMBFolderPickerView` to let the
/// user choose which subfolder of the share is the library root.
///
/// Discovery lifecycle mirrors `LoginView`: `deps.smbDiscovery.start()` on appear,
/// `stop()` on disappear, `#if !os(tvOS)` gated because tvOS has no mDNS LAN discovery
/// prompt and the Bonjour browser is unconditional (no permission gate — safe to run on
/// tvOS too, but the picker rows are irrelevant on the 10-foot UI).
struct SMBLoginView: View {
    /// Called after a server is successfully saved (folder selected + stored in Keychain).
    var onAdded: () -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(\.scenePhase) private var scenePhase

    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    /// Defaulted, not user-editable — the redesign drops the Domain field (4 fields per the handoff);
    /// WORKGROUP covers the overwhelming common case and the connection still passes it through.
    @State private var domain = "WORKGROUP"
    #if !os(tvOS)
    @State private var showPassword = false
    #endif

    @State private var isConnecting = false
    @State private var connectionError: String?

    /// The live lister handed to the picker AFTER a successful connection test.
    /// Holding it here (not as a navigation value) because `AMSMB2Lister` is an actor
    /// and can't be made `Hashable` for `.navigationDestination(for:)`. Instead we push
    /// by setting this and using a `navigationDestination(isPresented:)` binding.
    @State private var pendingLister: AMSMB2Lister?
    @State private var showFolderPicker = false

    /// The in-flight connection test. Held so backing out (Menu → onDisappear) or a fresh tap can
    /// CANCEL it — without a handle the connect was fire-and-forget and couldn't be stopped, so a
    /// slow/dead host wedged the spinner with no way out.
    @State private var connectTask: Task<Void, Never>?

    #if !os(tvOS)
    /// Return-key field walk: return advances to the next field, "go" on the last (password) connects.
    /// `allCases` order is the field sequence `submitChain` reads.
    @FocusState private var focusedField: Field?
    private enum Field: CaseIterable { case host, share, username, password }
    #endif

    /// Host + share are required; the account is optional (blank = guest, per the handoff footer).
    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
        && !share.trimmingCharacters(in: .whitespaces).isEmpty
        && !isConnecting
    }

    var body: some View {
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
                discoveredServersSection
                #endif

                fieldsSection

                if let error = connectionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.headerInset)
                }

                connectButton
            }
        }
        #if !os(tvOS)
        .onAppear { deps.smbDiscovery.start() }
        .onDisappear { deps.smbDiscovery.stop() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            deps.smbDiscovery.start()
        }
        #endif
        // Cancel any in-flight connection test when leaving the form (Menu/Back) so a slow or dead
        // host's attempt is torn down instead of completing into a dismissed view.
        .onDisappear { connectTask?.cancel() }
        .navigationDestination(isPresented: $showFolderPicker) {
            if let lister = pendingLister {
                SMBFolderPickerView(
                    lister: lister,
                    host: host,
                    share: share,
                    username: username,
                    password: password,
                    domain: domain,
                    onAdded: onAdded
                )
            }
        }
    }

    // MARK: - Discovered servers

    #if !os(tvOS)
    @ViewBuilder
    private var discoveredServersSection: some View {
        if !deps.smbDiscovery.discovered.isEmpty {
            SettingsGroup(title: "Discovered") {
                ForEach(deps.smbDiscovery.discovered) { server in
                    SettingsListRow(
                        systemImage: "network",
                        title: server.name,
                        subtitle: server.host
                    ) {
                        host = server.host
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
    private var fieldsSection: some View {
        #if os(tvOS)
        // The last field's keyboard "go" connects, gated to a complete form — same as the Connect button.
        CredentialRowList(rows: credentialRows, onSubmit: { if canConnect { connect() } })
        #else
        connectionFieldsSection
        #endif
    }

    #if os(tvOS)
    private var credentialRows: [CredentialRow] {
        [
            CredentialRow(id: "host", title: "Server", placeholder: "e.g. 192.168.1.10", text: $host, keyboard: .URL),
            CredentialRow(id: "share", title: "Share", placeholder: "Share name", text: $share),
            CredentialRow(id: "username", title: "Username", placeholder: "Optional", text: $username),
            CredentialRow(id: "password", title: "Password", placeholder: "Optional", text: $password, isSecure: true),
        ]
    }
    #endif

    #if !os(tvOS)
    private var connectionFieldsSection: some View {
        VStack(spacing: Space.s18) {
            SettingsGroup(
                title: "Server",
                footer: "Your server’s address, then the name of the shared folder to open."
            ) {
                CredentialFieldRow(icon: "externaldrive.badge.wifi") {
                    HStack(spacing: 0) {
                        Text("smb://").foregroundStyle(Color.tertiaryLabel)
                        TextField("mynas.local", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitChain(.host, focus: $focusedField, onComplete: handleSubmit)
                    }
                }
                CredentialFieldRow(icon: "folder") {
                    TextField("Share name", text: $share)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitChain(.share, focus: $focusedField, onComplete: handleSubmit)
                }
            }
            SettingsGroup(title: "Sign In", footer: "Leave blank to connect as a guest.") {
                CredentialFieldRow(icon: "person") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitChain(.username, focus: $focusedField, onComplete: handleSubmit)
                }
                CredentialFieldRow(icon: "lock") {
                    HStack {
                        Group {
                            if showPassword { TextField("Password", text: $password) }
                            else { SecureField("Password", text: $password) }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitChain(.password, focus: $focusedField, onComplete: handleSubmit)
                        PasswordRevealToggle(isRevealed: $showPassword)
                    }
                }
            }
        }
    }

    /// "Go" on the last field connects, but only when host / share / username are filled — the same
    /// gate the Connect button enforces, so return on an incomplete form is a no-op.
    private func handleSubmit() {
        guard canConnect else { return }
        connect()
    }
    #endif

    // MARK: - Connect button

    /// ONE button that MORPHS Connect ⇄ Cancel — never a disabled Connect plus a separately-inserted
    /// Cancel. On tvOS, disabling the *focused* control strands the focus engine: focus has nowhere to
    /// land (the just-appeared Cancel doesn't receive it), so the D-pad goes dead and Menu can't pop —
    /// the reported freeze. Keeping a single button with a STABLE identity means focus never moves: it
    /// stays focusable while connecting and tapping it cancels, so there's always a live focus target
    /// and a way out. The label shows the shared working spinner (the `formActionLabel` idiom) so the
    /// in-flight state still reads.
    private var connectButton: some View {
        Button {
            if isConnecting { cancelConnect() } else { connect() }
        } label: {
            Text(isConnecting ? "Cancel" : "Connect")
                .formActionLabel(.solid, isWorking: isConnecting)
        }
        .formActionButton(.solid)
        // Disabled ONLY when idle with an incomplete form — never while connecting, or focus is
        // stranded the instant the button would shed focus.
        .disabled(!isConnecting && !canConnect)
    }

    // MARK: - Connection logic

    private func connect() {
        let trimHost = host.trimmingCharacters(in: .whitespaces)
        let trimShare = share.trimmingCharacters(in: .whitespaces)
        let trimUser = username.trimmingCharacters(in: .whitespaces)

        connectionError = nil
        isConnecting = true

        // Capture to avoid closing over @State bindings inside the Task.
        let capturedPassword = password
        let capturedDomain = domain

        // Replace any prior in-flight attempt and HOLD the handle so onDisappear / Cancel can stop
        // it. Post-`await` writes are gated on `!Task.isCancelled` so a backed-out attempt never
        // resurrects the spinner or pushes the folder picker over a dismissed view.
        connectTask?.cancel()
        connectTask = Task {
            let lister = AMSMB2Lister(
                host: trimHost,
                username: trimUser,
                password: capturedPassword,
                domain: capturedDomain
            )
            do {
                _ = try await lister.list(share: trimShare, path: "")
                guard !Task.isCancelled else { await lister.disconnect(); return }
                // Adopt the validated (trimmed) values so what we persist EXACTLY matches
                // what connected. SMBFolderPickerView reads these straight into the saved
                // SMBServerData, and the media-repo factory later reconnects with them — if
                // we persisted the raw, untrimmed fields, a stray space would reconnect to a
                // different host/share and fail (browse works, the grid throws). Password +
                // domain are left as typed: those are exactly what the connection used.
                host = trimHost
                share = trimShare
                username = trimUser
                // Hand the connected lister to the folder picker.
                pendingLister = lister
                showFolderPicker = true
            } catch {
                // Disconnect so the actor doesn't hold a dangling connection.
                await lister.disconnect()
                guard !Task.isCancelled else { return }
                // Never expose the password in the error message.
                connectionError = "Couldn't connect to \(trimHost)/\(trimShare). Check the host, share, and credentials."
            }
            isConnecting = false
        }
    }

    /// Abort an in-flight connection test and reset the form so the user isn't stranded on the
    /// spinner. The underlying AMSMB2 connect runs a C poll loop that can't observe Swift
    /// cancellation, but `AMSMB2Lister`'s connect timeout bounds it and dropping the result here
    /// frees the UI immediately.
    private func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        isConnecting = false
    }

}

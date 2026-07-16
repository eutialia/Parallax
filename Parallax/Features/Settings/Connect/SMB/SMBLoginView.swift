import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin

/// Add-SMB-server form: collects host + credentials, validates the connection by
/// enumerating shares, then hands off to `SMBShareSelectionView` to let the user
/// choose which shares to mount as libraries.
///
/// Discovery lifecycle mirrors `LoginView`: `deps.smbDiscovery.start()` on appear,
/// `stop()` on disappear, `#if !os(tvOS)` gated because tvOS has no mDNS LAN discovery
/// prompt and the Bonjour browser is unconditional (no permission gate — safe to run on
/// tvOS too, but the picker rows are irrelevant on the 10-foot UI).
struct SMBLoginView: View {
    /// Called after a server is successfully saved (shares selected + stored in Keychain).
    var onAdded: () -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(\.scenePhase) private var scenePhase

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    /// Defaulted, not user-editable — the redesign drops the Domain field (4 fields per the handoff);
    /// WORKGROUP covers the overwhelming common case and the connection still passes it through.
    @State private var domain = "WORKGROUP"
    #if !os(tvOS)
    @State private var showPassword = false
    #endif

    @State private var connectionError: String?

    /// The live lister handed to the share selector AFTER a successful enumeration.
    /// Holding it here (not as a navigation value) because `AMSMB2Lister` is an actor
    /// and can't be made `Hashable` for `.navigationDestination(for:)`. Instead we push
    /// by setting this and using a `navigationDestination(isPresented:)` binding.
    @State private var pendingLister: AMSMB2Lister?
    @State private var discoveredShares: [SMBShare] = []
    @State private var showShareSelector = false

    /// The in-flight connection test. Held so backing out (Menu → onDisappear) or a fresh tap can
    /// CANCEL it — without a handle the connect was fire-and-forget and couldn't be stopped, so a
    /// slow/dead host wedged the spinner with no way out.
    @State private var connectTask: Task<Void, Never>?
    /// UI-level failsafe over the whole connect attempt. The lister already hard-bounds every
    /// AMSMB2 call, yet a device run still spun forever — so the attempt is ALSO bounded here,
    /// above every layer this view awaits. Runs on the MainActor: if IT doesn't fire either, the
    /// main actor itself is wedged (which the ticking elapsed counter makes visible).
    @State private var watchdogTask: Task<Void, Never>?
    /// When the in-flight attempt started — drives the elapsed counter AND is the single source
    /// of the connecting state: `isConnecting` derives from it, so "connecting with no start
    /// time" is unrepresentable and every exit path resets ONE value.
    @State private var connectStartedAt: Date?
    /// Diagnostic breadcrumb: the last stage the connect attempt reached, surfaced by the
    /// watchdog's DEBUG error message. Reference-typed on purpose — stage transitions are
    /// diagnostics, not display state, so writing them must not invalidate the form's view tree.
    @State private var diagnostics = ConnectDiagnostics()
    /// Incremented on Connect; `CredentialRowList` resigns any stale hidden-field first responder
    /// when it moves (see the sweep rationale there).
    @State private var fieldSweep = 0

    /// The form is mid-attempt. Derived — see `connectStartedAt`.
    private var isConnecting: Bool { connectStartedAt != nil }

    #if !os(tvOS)
    /// Return-key field walk: return advances to the next field, "go" on the last (password) connects.
    /// `allCases` order is the field sequence `submitChain` reads.
    @FocusState private var focusedField: Field?
    private enum Field: CaseIterable { case host, username, password }
    #endif

    /// Host is required; the account is optional (blank = guest, per the handoff footer).
    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
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

                // Live elapsed counter while connecting. Doubles as a diagnostic: it ticks on the
                // MainActor, so a counter that FREEZES mid-attempt means the main actor is wedged
                // (spinners keep animating in the render server and prove nothing).
                if let startedAt = connectStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                        Text("Connecting… \(elapsed)s")
                            .font(.footnote)
                            .foregroundStyle(Color.secondaryLabel)
                            .monospacedDigit()
                    }
                }
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
        // Tear down any in-flight connection test when leaving the form (Menu/Back, or a tab
        // switch away) — a full reset, not just task cancellation: a cancelled task's early
        // returns skip the epilogue, and a bare cancel left `connectStartedAt` set, so switching
        // tabs mid-connect and back showed a stale Cancel+spinner with no live task behind it.
        .onDisappear { cancelConnect() }
        .navigationDestination(isPresented: $showShareSelector) {
            if let lister = pendingLister {
                SMBShareSelectionView(
                    lister: lister,
                    host: host,
                    username: username,
                    password: password,
                    domain: domain,
                    shares: discoveredShares,
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
        // No last-field auto-connect: tvOS's system keyboard Done returns to the form, and the
        // always-present Connect button submits (gated to a complete form).
        CredentialRowList(rows: credentialRows, sweepToken: fieldSweep)
        #else
        connectionFieldsSection
        #endif
    }

    #if os(tvOS)
    private var credentialRows: [CredentialRow] {
        [
            CredentialRow(id: "host", title: "Server", placeholder: "e.g. 192.168.1.10", text: $host, keyboard: .URL),
            CredentialRow(id: "username", title: "Username", placeholder: "Optional", text: $username),
            CredentialRow(id: "password", title: "Password", placeholder: "Optional", text: $password, isSecure: true),
        ]
    }
    #endif

    #if !os(tvOS)
    private var connectionFieldsSection: some View {
        VStack(spacing: Space.s18) {
            SettingsGroup(title: "Server") {
                CredentialFieldRow(icon: "externaldrive.badge.wifi") {
                    HStack(spacing: 0) {
                        Text("smb://").foregroundStyle(Color.tertiaryLabel)
                        // Placeholder must read as an OBVIOUS example: a plausible real-looking
                        // hostname here ("mynas.local") was mistaken for a LAN-discovered value.
                        TextField("mynas.local", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitChain(.host, focus: $focusedField, onComplete: handleSubmit)
                    }
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

    /// "Go" on the last field connects, but only when the host is filled — the same
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
    /// and a way out. While working, `formActionLabel` keeps the "Cancel" title VISIBLE beside the
    /// spinner — hidden, the in-flight button read as a frozen blank pill on Apple TV.
    private var connectButton: some View {
        Button {
            if isConnecting { cancelConnect() } else { connect() }
        } label: {
            Text(isConnecting ? "Cancel" : "Connect")
                .formActionLabel(isWorking: isConnecting)
        }
        .formActionButton(.solid)
        // Disabled ONLY when idle with an incomplete form — never while connecting, or focus is
        // stranded the instant the button would shed focus.
        .disabled(!isConnecting && !canConnect)
    }

    // MARK: - Connection logic

    private func connect() {
        let trimHost = host.trimmingCharacters(in: .whitespaces)
        let trimUser = username.trimmingCharacters(in: .whitespaces)

        connectionError = nil
        connectStartedAt = Date()
        diagnostics.stage = "queued"
        // Release any hidden credential field tvOS left as first responder — the prime suspect
        // for Menu presses dying during a connect (see CredentialRowList's sweep rationale).
        fieldSweep += 1

        // Capture to avoid closing over @State bindings inside the Task.
        let capturedPassword = password
        let capturedDomain = domain

        // Replace any prior in-flight attempt and HOLD the handle so onDisappear / Cancel can stop
        // it. Post-`await` writes are gated on `!Task.isCancelled` so a backed-out attempt never
        // resurrects the spinner or pushes the share selector over a dismissed view.
        connectTask?.cancel()
        connectTask = Task {
            diagnostics.stage = "task-started"
            let lister = AMSMB2Lister(
                host: trimHost,
                username: trimUser,
                password: capturedPassword,
                domain: capturedDomain
            )
            do {
                diagnostics.stage = "listing-shares"
                let shares = try await lister.listShares()
                diagnostics.stage = "listed(\(shares.count))"
                guard !Task.isCancelled else { await lister.disconnect(); return }
                // A server can enumerate ZERO visible shares (everything hidden/admin —
                // `listShares` filters `$` shares). Pushing the picker then strands the tvOS
                // focus engine on a screen whose only control is the disabled Add button — no
                // focusable element, dead remote. Surface it as an inline error instead.
                guard !shares.isEmpty else {
                    await lister.disconnect()
                    connectionError = "\(trimHost) has no shares to add. Check the server's shared folders."
                    connectStartedAt = nil
                    watchdogTask?.cancel()
                    return
                }
                // Adopt the validated (trimmed) values so what we persist EXACTLY matches
                // what connected. SMBShareSelectionView reads these straight into the saved
                // SMBServerData, and the media-repo factory later reconnects with them — if
                // we persisted the raw, untrimmed fields, a stray space would reconnect to a
                // different host and fail. Password + domain are left as typed: those are
                // exactly what the connection used.
                host = trimHost
                username = trimUser
                // Hand the connected lister + discovered shares to the selector.
                pendingLister = lister
                discoveredShares = shares
                showShareSelector = true
            } catch {
                diagnostics.stage = "threw"
                // Disconnect so the actor doesn't hold a dangling connection.
                await lister.disconnect()
                guard !Task.isCancelled else { return }
                // Never expose the password in the error message.
                connectionError = "Couldn't connect to \(trimHost). Check the host and credentials."
            }
            connectStartedAt = nil
            watchdogTask?.cancel()
        }

        // UI failsafe ABOVE every awaited layer: the lister hard-bounds each AMSMB2 call, yet a
        // device run still spun forever — whatever wedges below, this frees the form. It runs on
        // the MainActor, so if the error never appears AND the elapsed counter stops ticking, the
        // main actor itself is blocked — that distinction is the diagnostic this exists for.
        watchdogTask?.cancel()
        watchdogTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, isConnecting else { return }
            connectTask?.cancel()
            connectTask = nil
            connectStartedAt = nil
            #if DEBUG
            connectionError = "Timed out after 30 s (stage: \(diagnostics.stage))."
            #else
            connectionError = "Timed out. Check the host and try again."
            #endif
        }
    }

    /// Abort an in-flight connection test and reset the form so the user isn't stranded on the
    /// spinner. The underlying AMSMB2 connect runs a C poll loop that can't observe Swift
    /// cancellation, but the lister's hard timeout bounds it and dropping the result here
    /// frees the UI immediately.
    private func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        connectStartedAt = nil
    }

}

/// Mutable, non-observed connect diagnostics (see `SMBLoginView.diagnostics`): a reference type so
/// breadcrumb writes bypass SwiftUI invalidation entirely.
@MainActor
private final class ConnectDiagnostics {
    var stage = "idle"
}

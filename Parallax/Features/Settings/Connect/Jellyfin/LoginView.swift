import SwiftUI
import ParallaxJellyfin

/// The Jellyfin sign-in form. Pushed as a screen on both paths now — from the logged-out Connect
/// picker and from Settings' "Add Server" — so it owns its own view model and wears the shared
/// `SettingsScaffold` (brand rail) like every other settings/connect surface. No more in-place slide
/// (the picker pushes via its `NavigationStack`), so the chromeless / onBack / external-VM plumbing the
/// slide needed is gone.
struct LoginView: View {
    /// Called after a successful sign-in. When nil (the logged-out Connect path) the view drives the
    /// router itself; Settings' add-server flow passes a closure to refresh + pop.
    var onSignedIn: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: LoginViewModel?
    /// Incremented on Connect; `CredentialRowList` releases any stale hidden-field first responder
    /// when it moves (tvOS-only effect — see the sweep rationale there).
    @State private var fieldSweep = 0
    #if !os(tvOS)
    @State private var showPassword = false
    /// Drives the return-key field walk: return advances to the next field, and "go" on the last
    /// (password) submits. Declared in `allCases` order, which `submitChain` reads as the sequence.
    @FocusState private var focusedField: Field?
    private enum Field: CaseIterable { case server, username, password }
    #endif

    var body: some View {
        // No brand on the sign-in form itself: it's always PUSHED from a choose-type screen (first-run's
        // ConnectSourceView or Settings' AddServerChooseView) which owns the brand/intro, so it reads
        // under its "Jellyfin" nav title — re-showing the lockup here would double-brand the flow.
        SettingsScaffold(showsBrand: false) { signInBody }
        #if !os(tvOS)
        .onAppear {
            // Discovery runs only while this screen is visible. Triggers the iOS Local Network
            // permission prompt here (not mid-library browse) and fills the server URL / LAN list
            // below. Retries catch a late grant during the permission alert; stop() on disappear
            // cancels in-flight passes once the user leaves sign-in.
            deps.lanDiscovery.start(retries: 3, retryInterval: .seconds(2))
        }
        .onDisappear {
            deps.lanDiscovery.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // iOS exposes no Local Network authorization API — rescan when the scene becomes active
            // again (e.g. user tapped Allow then returned).
            guard newPhase == .active else { return }
            deps.lanDiscovery.start()
        }
        #endif
        .task {
            if viewModel == nil {
                viewModel = LoginViewModel(sessionManager: deps.sessionManager)
            }
            #if !os(tvOS)
            // Auto-fill the server URL from LAN discovery when the field is empty (most networks have
            // a single Jellyfin server).
            if let vm = viewModel, vm.serverURLInput.isEmpty,
               let first = deps.lanDiscovery.discovered.first {
                vm.serverURLInput = first.address.absoluteString
            }
            #endif
        }
        #if !os(tvOS)
        // Discovery usually completes AFTER the view appears (it races the Local Network permission
        // prompt), so fill the URL in when it lands.
        .onChange(of: deps.lanDiscovery.discovered.first?.address) { _, address in
            if let address, let vm = viewModel, vm.serverURLInput.isEmpty {
                vm.serverURLInput = address.absoluteString
            }
        }
        #endif
    }

    @ViewBuilder
    private var signInBody: some View {
        if let vm = viewModel {
            Group {
                switch vm.mode {
                case .password:
                    passwordBody(vm: vm)
                case .quickConnect:
                    QuickConnectView(
                        serverURLInput: vm.serverURLInput,
                        onSwitchToPassword: { vm.switchToPassword() },
                        onSignedIn: { Task { await handleSuccess() } }
                    )
                }
            }
            // Identity tied to the mode so the swap is a real insert/remove that the transition
            // animates (a transition on a stable wrapper wouldn't fire); driven by the withAnimation
            // at the toggle sites.
            .id(vm.mode)
            // Reduce Motion swaps the blur-replace for a plain cross-fade (the app-wide gating idiom).
            // Both arms are boxed as AnyTransition — `.blurReplace` is a `Transition`, not an
            // `AnyTransition` member, so the ternary can't unify them unwrapped.
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
        } else {
            LoginCardLoadingSkeleton()
        }
    }

    @ViewBuilder
    private func passwordBody(vm: LoginViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: Space.s18) {
            #if os(tvOS)
            // tvOS has no nav bar (the native pill only reads "Settings"), so the form carries its own
            // identity inline (handoff `.fhead`). iOS shows the "Jellyfin" nav title instead.
            FormIntroHeader(
                glyph: .templateImage("JellyfinGlyph"),
                title: "Sign in to Jellyfin",
                subtitle: "Enter your server address and account. Or use Quick Connect to approve from your phone — no typing on the remote."
            )
            .padding(.bottom, Space.s8)
            #endif

            #if !os(tvOS)
            // LAN-discovered servers as a grouped section: tap to quick-fill the URL.
            if !deps.lanDiscovery.discovered.isEmpty {
                SettingsGroup(title: "Discovered") {
                    ForEach(deps.lanDiscovery.discovered) { server in
                        SettingsListRow(
                            systemImage: "wifi",
                            title: server.name,
                            subtitle: server.address.absoluteString
                        ) {
                            vm.serverURLInput = server.address.absoluteString
                        }
                    }
                }
            }
            #endif

            // Field stack — tvOS uses the Settings-style row list (rows → single-field keyboard screen);
            // iOS uses the inset-grouped fields. See `CredentialRowList` for why the inline tvOS field is avoided.
            #if os(tvOS)
            // `sweepToken` mirrors SMBLoginView: bumped on Connect so any hidden credential field
            // tvOS retained as first responder is released before the sign-in — a stale first
            // responder can swallow the remote's Menu press (the add-SMB freeze's parallel path).
            CredentialRowList(rows: [
                CredentialRow(id: "server", title: "Server", placeholder: "https://jellyfin.example.com", text: $vm.serverURLInput, keyboard: .URL, textContentType: .URL),
                CredentialRow(id: "username", title: "Username", placeholder: "Username", text: $vm.username, textContentType: .username),
                CredentialRow(id: "password", title: "Password", placeholder: "Password", text: $vm.password, isSecure: true, textContentType: .password),
            ], sweepToken: fieldSweep)
            #else
            SettingsGroup(title: "Server") {
                CredentialFieldRow(icon: "globe") {
                    TextField("", text: $vm.serverURLInput, prompt: Self.urlPrompt)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitChain(.server, focus: $focusedField, onComplete: { handleSubmit(vm: vm) })
                }
            }
            SettingsGroup(title: "Account") {
                CredentialFieldRow(icon: "person") {
                    TextField("Username", text: $vm.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.username)
                        .submitChain(.username, focus: $focusedField, onComplete: { handleSubmit(vm: vm) })
                }
                CredentialFieldRow(icon: "lock") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $vm.password)
                            } else {
                                SecureField("Password", text: $vm.password)
                            }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        // Tag both states .password so the "Show" toggle's plain TextField keeps AutoFill alive.
                        .textContentType(.password)
                        .submitChain(.password, focus: $focusedField, onComplete: { handleSubmit(vm: vm) })
                        PasswordRevealToggle(isRevealed: $showPassword)
                    }
                }
            }
            #endif

            if let error = vm.errorMessage {
                Text(error).font(.footnote).foregroundStyle(Color.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.headerInset)
            }

            // Connect (solid primary) — needs all three fields before it's tappable.
            Button {
                fieldSweep += 1
                Task { await submitSignIn(vm: vm) }
            } label: {
                Text("Connect").formActionLabel(isWorking: vm.isWorking)
            }
            .formActionButton(.solid)
            .disabled(vm.isWorking || !vm.canSubmitPassword)
            .padding(.top, Space.s3)

            // OR divider
            HStack(spacing: Space.s12) {
                Rectangle().fill(Color.separator).frame(height: 1)
                Text("or").textCase(.uppercase).font(.caption.weight(.semibold)).foregroundStyle(Color.tertiaryLabel)
                Rectangle().fill(Color.separator).frame(height: 1)
            }

            // Quick Connect (glass) — needs a server URL to pair against.
            Button {
                withAnimation(reduceMotion ? nil : .smooth) { vm.switchToQuickConnect() }
            } label: {
                Label("Use Quick Connect", systemImage: "bolt.fill")
                    .formActionLabel()
            }
            .formActionButton(.glass)
            .disabled(!vm.canUseQuickConnect)

            // Quick Connect explainer footer (parity with the other forms' grouped footers).
            Text("Quick Connect signs you in with a code from your server — no password needed.")
                .font(.rowSubtitle)
                .foregroundStyle(Color.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s3)
        }
    }

    private func submitSignIn(vm: LoginViewModel) async {
        if await vm.signIn() { await handleSuccess() }
    }

    #if !os(tvOS)
    /// The iOS return chain's submit on the last field — only fires a sign-in when all three fields are
    /// filled; an incomplete form is a no-op, the same gate the Connect button enforces. tvOS has no
    /// last-field submit: its system keyboard's Done returns to the form and the Connect button signs in.
    private func handleSubmit(vm: LoginViewModel) {
        // `!vm.isWorking` too: the Button is disabled while signing in, but the keyboard bypasses it —
        // without this a fast double-submit spawns two concurrent signIn()s.
        guard vm.canSubmitPassword, !vm.isWorking else { return }
        Task { await submitSignIn(vm: vm) }
    }
    #endif

    // MARK: - iOS inline field helpers (tvOS uses CredentialRowList)

    #if !os(tvOS)
    /// URL-shaped placeholders get auto-styled as blue links, which ignores `.tint` and
    /// `.foregroundStyle`. Feeding the example as an `AttributedString` with an explicit color renders
    /// it in the normal placeholder gray instead.
    private static var urlPrompt: Text {
        var prompt = AttributedString("https://jellyfin.example.com")
        prompt.swiftUI.foregroundColor = Color.tertiaryLabel
        return Text(prompt)
    }
    #endif

    private func handleSuccess() async {
        if let onSignedIn {
            // Settings add-server flow: the caller refreshes its list, re-points the router, and pops
            // this view off the settings stack.
            onSignedIn()
        } else {
            // First sign-in (logged-out Connect): set destination AND activeServerID together. The
            // per-source tasks (Home/Library/Search/RootTabView) are gated on the router's source
            // state, so routing through `updateForSources` is what actually lets them fetch — setting
            // only `destination` would strand every tab on its loading skeleton.
            router.updateForSources(
                activeSession: await deps.serverStore.active,
                hasAuxiliarySources: await deps.serverStore.hasSMBServers
            )
        }
    }
}

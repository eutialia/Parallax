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
    #if !os(tvOS)
    @State private var showPassword = false
    /// Drives the return-key field walk: return advances to the next field, and "go" on the last
    /// (password) submits. Declared in `allCases` order, which `submitChain` reads as the sequence.
    @FocusState private var focusedField: Field?
    private enum Field: CaseIterable { case server, username, password }
    #endif

    var body: some View {
        SettingsScaffold(brandSubtitle: "Sign in to your Jellyfin server") { signInBody }
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
        VStack(spacing: Space.s22) {
            #if !os(tvOS)
            // LAN-discovered servers as capsule pills (the settings-row idiom): tap to quick-fill the URL.
            if !deps.lanDiscovery.discovered.isEmpty {
                VStack(spacing: .credentialPillGap) {
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

            // Field stack — tvOS uses the Settings-style row list (rows → single-field keyboard
            // screen, no inline field pill); iOS keeps the inline grouped fields. See
            // `CredentialRowList` for why the inline tvOS field pill is avoided.
            #if os(tvOS)
            CredentialRowList(rows: [
                CredentialRow(id: "server", title: "Server", placeholder: "https://jellyfin.example.com", text: $vm.serverURLInput, keyboard: .URL, textContentType: .URL),
                CredentialRow(id: "username", title: "Username", placeholder: "Username", text: $vm.username, textContentType: .username),
                CredentialRow(id: "password", title: "Password", placeholder: "Password", text: $vm.password, isSecure: true, textContentType: .password),
            ], onSubmit: { handleSubmit(vm: vm) })
            #else
            VStack(spacing: .credentialPillGap) {
                CredentialFieldPill(icon: "globe") {
                    TextField("", text: $vm.serverURLInput, prompt: Self.urlPrompt)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitChain(.server, focus: $focusedField, onComplete: { handleSubmit(vm: vm) })
                }
                CredentialFieldPill(icon: "person") {
                    TextField("Username", text: $vm.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.username)
                        .submitChain(.username, focus: $focusedField, onComplete: { handleSubmit(vm: vm) })
                }
                CredentialFieldPill(icon: "lock") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $vm.password)
                            } else {
                                SecureField("Password", text: $vm.password)
                            }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        // Tag both states .password: the heuristics treat a non-secure field as a
                        // password only when told, so the "Show" toggle's plain TextField keeps
                        // AutoFill alive. Surfaces the QuickType key icon (all saved logins) even
                        // without an associated domain — the realistic fill path for self-hosted URLs.
                        .textContentType(.password)
                        .submitChain(.password, focus: $focusedField, onComplete: { handleSubmit(vm: vm) })
                        Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                            .font(.footnote).foregroundStyle(Color.secondaryLabel)
                            .buttonStyle(.borderless)
                    }
                }
            }
            #endif

            if let error = vm.errorMessage {
                Text(error).font(.footnote).foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Connect (solid primary) — needs all three fields before it's tappable.
            Button {
                Task { await submitSignIn(vm: vm) }
            } label: {
                Text("Connect").formActionLabel(.solid, isWorking: vm.isWorking)
            }
            .formActionButton(.solid)
            .disabled(vm.isWorking || !vm.canSubmitPassword)

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
                    .formActionLabel(.glass)
            }
            .formActionButton(.glass)
            .disabled(!vm.canUseQuickConnect)
        }
    }

    private func submitSignIn(vm: LoginViewModel) async {
        if await vm.signIn() { await handleSuccess() }
    }

    /// The keyboard's submit on the last field — the iOS return chain AND the tvOS `CredentialRowList`
    /// "go" key both route here — only fires a sign-in when all three fields are filled; an incomplete
    /// form is a no-op, the same gate the Connect button enforces.
    private func handleSubmit(vm: LoginViewModel) {
        // `!vm.isWorking` too: the Button is disabled while signing in, but the keyboard bypasses it —
        // without this a fast double-submit spawns two concurrent signIn()s.
        guard vm.canSubmitPassword, !vm.isWorking else { return }
        Task { await submitSignIn(vm: vm) }
    }

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

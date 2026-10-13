import SwiftUI
import ParallaxJellyfin
import ParallaxFeatures

/// The Jellyfin sign-in form. Pushed as a screen on both paths now — from the logged-out Connect
/// picker and from Settings' "Add Server" — so it owns its own view model and wears the shared
/// `SettingsScaffold` (brand rail) like every other settings/connect surface. No more in-place slide
/// (the picker pushes via its `NavigationStack`), so the chromeless / onBack / external-VM plumbing the
/// slide needed is gone.
struct LoginView: View {
    /// Seeds the server field when re-authenticating a server Parallax already knows — a signed-out
    /// row whose token was lost or revoked. Nil for a genuine add, where the field starts empty (and
    /// LAN discovery may fill it). Set, it also suppresses that autofill: a discovered LAN server is
    /// a guess, and it must not overwrite the exact address the user asked to sign back into.
    var prefilledServerURL: String?
    /// Called after a successful sign-in. When nil (the logged-out Connect path) the view drives the
    /// router itself via the model; Settings' add-server flow passes a closure to refresh + pop.
    var onSignedIn: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    @State private var viewModel: LoginViewModel?
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
        .task {
            if viewModel == nil {
                viewModel = LoginViewModel(app: app, prefilledServerURL: prefilledServerURL, onSignedIn: onSignedIn)
            }
            #if !os(tvOS)
            await viewModel?.discoverServers()
            #endif
        }
    }

    @ViewBuilder
    private var signInBody: some View {
        if let vm = viewModel {
            Group {
                switch vm.mode {
                case .password:
                    passwordBody(vm: vm)
                case .quickConnect:
                    QuickConnectView(login: vm)
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
            if !vm.discoveredServers.isEmpty {
                SettingsGroup(title: "Discovered") {
                    ForEach(vm.discoveredServers) { server in
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
            CredentialRowList(rows: [
                CredentialRow(id: "server", title: "Server", placeholder: "https://jellyfin.example.com", text: $vm.serverURLInput, keyboard: .URL, textContentType: .URL),
                CredentialRow(id: "username", title: "Username", placeholder: "Username", text: $vm.username, textContentType: .username),
                CredentialRow(id: "password", title: "Password", placeholder: "Password", text: $vm.password, isSecure: true, textContentType: .password),
            ])
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

            // Connect (solid primary) — needs a server and a username; passwordless Jellyfin
            // accounts are valid, so the password field is not part of the gate.
            Button {
                Task { await vm.submit() }
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

    #if !os(tvOS)
    /// The iOS return chain's submit on the last field — only fires a sign-in when the server and
    /// username are filled (the password is optional, see `canSubmitPassword`); an incomplete form is
    /// a no-op, the same gate the Connect button enforces. tvOS has no
    /// last-field submit: its system keyboard's Done returns to the form and the Connect button signs in.
    private func handleSubmit(vm: LoginViewModel) {
        // `!vm.isWorking` too: the Button is disabled while signing in, but the keyboard bypasses it —
        // without this a fast double-submit spawns two concurrent signIn()s.
        guard vm.canSubmitPassword, !vm.isWorking else { return }
        Task { await vm.submit() }
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
}

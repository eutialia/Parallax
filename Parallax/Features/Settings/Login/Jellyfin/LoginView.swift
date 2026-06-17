import SwiftUI
import ParallaxJellyfin

struct LoginView: View {
    /// Called after a successful sign-in. When nil (the logged-out root) the view drives
    /// the router itself; the settings add-server flow passes a closure to refresh + pop.
    var onSignedIn: (() -> Void)?

    /// Body-only mode: skip the scaffold + brand mark (the logged-out source picker supplies them,
    /// rendering the "Parallax" mark ONCE above the sliding bodies so it stays put). Settings leaves
    /// this false and gets the full chrome.
    var chromeless: Bool = false

    /// When set, the password body shows a bottom "Choose a different source" control. Used by the
    /// logged-out picker (in-place swap, no system back); nil in settings, where the nav stack's
    /// back button handles it.
    var onBack: (() -> Void)?

    /// An externally-owned view model. The logged-out source picker hands one it holds, so the
    /// typed server URL / username / password survive the swap back to the picker and forward
    /// again — the cover transition removes and re-inserts this subtree, which would otherwise
    /// reset its own `@State` and wipe the form. Settings leaves this nil and the view owns its own.
    var viewModelOverride: LoginViewModel?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: LoginViewModel?
    #if !os(tvOS)
    @State private var showPassword = false
    /// Shared height for the iOS form's text-field rows, scaling with Dynamic Type so labels never
    /// clip at larger text sizes. (tvOS uses `CredentialRowList`, not these inline rows.)
    @ScaledMetric(relativeTo: .headline) private var baseControlHeight: CGFloat = 50
    #endif

    var body: some View {
        content
        #if !os(tvOS)
        .onAppear {
            // Discovery runs only while this screen is visible. Triggers the iOS
            // Local Network permission prompt here (not mid-library browse) and
            // fills the server URL / LAN list below. Retries catch a late grant
            // during the permission alert; stop() on disappear cancels in-flight
            // passes once the user leaves sign-in.
            deps.lanDiscovery.start(retries: 3, retryInterval: .seconds(2))
        }
        .onDisappear {
            deps.lanDiscovery.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // iOS exposes no Local Network authorization API — rescan when the
            // scene becomes active again (e.g. user tapped Allow then returned).
            guard newPhase == .active else { return }
            deps.lanDiscovery.start()
        }
        #endif
        .task {
            if viewModel == nil {
                viewModel = viewModelOverride ?? LoginViewModel(sessionManager: deps.sessionManager)
            }
            #if !os(tvOS)
            // Auto-fill the server URL from LAN discovery when the field is empty
            // (most networks have a single Jellyfin server).
            if let vm = viewModel, vm.serverURLInput.isEmpty,
               let first = deps.lanDiscovery.discovered.first {
                vm.serverURLInput = first.address.absoluteString
            }
            #endif
        }
        #if !os(tvOS)
        // Discovery usually completes AFTER the view appears (it races the Local
        // Network permission prompt), so fill the URL in when it lands.
        .onChange(of: deps.lanDiscovery.discovered.first?.address) { _, address in
            if let address, let vm = viewModel, vm.serverURLInput.isEmpty {
                vm.serverURLInput = address.absoluteString
            }
        }
        #endif
    }

    /// Chromeless: just the body (picker supplies the mark + scaffold). Otherwise wrap the body in
    /// the scaffold with the persistent "Parallax" mark above it (the mark sits OUTSIDE the
    /// password ↔ Quick Connect swap, so it doesn't flicker when the mode changes).
    @ViewBuilder
    private var content: some View {
        if chromeless {
            signInBody
        } else {
            AuthScreenScaffold {
                VStack(spacing: Space.s22) {
                    AuthBrandMark(glyph: .brandIcon, title: "Parallax")
                    signInBody
                }
            }
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
                    QuickConnectView(
                        serverURLInput: vm.serverURLInput,
                        onSwitchToPassword: { vm.switchToPassword() },
                        onSignedIn: { Task { await handleSuccess() } }
                    )
                }
            }
            // Identity tied to the mode so the swap is a real insert/remove that the
            // transition animates (a transition on a stable wrapper wouldn't fire);
            // driven by the withAnimation at the toggle sites.
            .id(vm.mode)
            .transition(.blurReplace)
        } else {
            VStack(spacing: Space.s22) {
                AuthSubtitle("Sign in to your Jellyfin server")
                LoginCardLoadingSkeleton()
            }
        }
    }

    @ViewBuilder
    private func passwordBody(vm: LoginViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: Space.s22) {
            AuthSubtitle("Sign in to your Jellyfin server")

            #if !os(tvOS)
            // LAN-discovered servers (relocated): tap to quick-fill the URL.
            if !deps.lanDiscovery.discovered.isEmpty {
                VStack(spacing: 0) {
                    ForEach(deps.lanDiscovery.discovered) { server in
                        Button {
                            vm.serverURLInput = server.address.absoluteString
                        } label: {
                            HStack(spacing: Space.s12) {
                                Image(systemName: "wifi").foregroundStyle(Color.secondaryLabel)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(server.name).font(.subheadline).foregroundStyle(Color.label)
                                    Text(server.address.absoluteString).font(.caption).foregroundStyle(Color.secondaryLabel)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, Space.s8)
                            .padding(.horizontal, Space.s14)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            }
            #endif

            // Field stack — tvOS uses the Settings-style row list (rows → single-field keyboard
            // screen, no inline field pill); iOS keeps the inline grouped fields. See
            // `CredentialRowList` for why the inline tvOS field pill is avoided.
            #if os(tvOS)
            CredentialRowList(rows: [
                CredentialRow(id: "server", icon: "globe", title: "Server", placeholder: "https://jellyfin.example.com", text: $vm.serverURLInput, keyboard: .URL),
                CredentialRow(id: "username", icon: "person", title: "Username", placeholder: "Username", text: $vm.username),
                CredentialRow(id: "password", icon: "lock", title: "Password", placeholder: "Password", text: $vm.password, isSecure: true),
            ])
            #else
            VStack(spacing: 0) {
                fieldRow(icon: "globe") {
                    TextField("", text: $vm.serverURLInput, prompt: Self.urlPrompt)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                hairline
                fieldRow(icon: "person") {
                    TextField("Username", text: $vm.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                hairline
                fieldRow(icon: "lock") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $vm.password)
                            } else {
                                SecureField("Password", text: $vm.password)
                            }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                            .font(.footnote).foregroundStyle(Color.secondaryLabel)
                            .buttonStyle(.borderless)
                    }
                }
            }
            .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            #endif

            if let error = vm.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Connect (solid primary) — needs all three fields before it's tappable.
            Button {
                Task { await submitSignIn(vm: vm) }
            } label: {
                Group {
                    if vm.isWorking { ProgressView().tint(Color.buttonLabel) }
                    else { Text("Connect") }
                }
                .formActionLabel(.solid)
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
                withAnimation(.smooth) { vm.switchToQuickConnect() }
            } label: {
                Label("Use Quick Connect", systemImage: "bolt.fill")
                    .formActionLabel(.glass)
            }
            .formActionButton(.glass)
            .disabled(!vm.canUseQuickConnect)

            // Logged-out picker only: a light return to the source choices, at the bottom (no system
            // back, since the picker swaps this form in place rather than pushing it).
            if let onBack {
                Button(action: onBack) {
                    Label("Choose a different source", systemImage: "chevron.left")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                .buttonStyle(.plain)
                .padding(.top, Space.s8)
                .accessibilityLabel("Back to connection options")
            }
        }
    }

    private func submitSignIn(vm: LoginViewModel) async {
        if await vm.signIn() { await handleSuccess() }
    }

    // MARK: - iOS inline field helpers (tvOS uses CredentialRowList)

    #if !os(tvOS)
    /// URL-shaped placeholders get auto-styled as blue links, which ignores `.tint`
    /// and `.foregroundStyle`. Feeding the example as an `AttributedString` with an
    /// explicit color renders it in the normal placeholder gray instead.
    private static var urlPrompt: Text {
        var prompt = AttributedString("https://jellyfin.example.com")
        prompt.swiftUI.foregroundColor = Color.tertiaryLabel
        return Text(prompt)
    }

    private var hairline: some View {
        Rectangle().fill(Color.separator).frame(height: 1).padding(.leading, 44)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.s12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(Color.tertiaryLabel)
            content()
        }
        .padding(.horizontal, Space.s14)
        .frame(height: baseControlHeight)
    }
    #endif

    private func handleSuccess() async {
        if let onSignedIn {
            // Settings add-server flow: the caller refreshes its list, re-points the
            // router, and pops this view off the settings stack.
            onSignedIn()
        } else {
            // First sign-in (logged-out root): set destination AND activeServerID together.
            // The per-server tasks (Home/Library/Search/RootTabView) are gated on
            // `activeServerID != nil`, so routing through `updateForCurrentSession` is what
            // actually lets them fetch — setting only `destination` would strand every tab
            // on its loading skeleton.
            router.updateForCurrentSession(await deps.serverStore.active)
        }
    }
}

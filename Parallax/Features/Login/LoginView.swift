import SwiftUI
import ParallaxJellyfin

struct LoginView: View {
    /// Called after a successful sign-in. When nil (the logged-out root) the view drives
    /// the router itself; the settings add-server flow passes a closure to refresh + pop.
    var onSignedIn: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: LoginViewModel?
    @State private var showPassword = false
    /// Shared height for the form's tap targets (fields + Connect + Quick Connect),
    /// scaling with Dynamic Type so labels never clip at larger text sizes.
    @ScaledMetric(relativeTo: .headline) private var controlHeight: CGFloat = 50

    var body: some View {
        ZStack {
            Color.background.ignoresSafeArea()
            content
        }
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
        .task {
            if viewModel == nil {
                viewModel = LoginViewModel(sessionManager: deps.sessionManager)
            }
            // Auto-fill the server URL from LAN discovery when the field is empty
            // (most networks have a single Jellyfin server).
            if let vm = viewModel, vm.serverURLInput.isEmpty,
               let first = deps.lanDiscovery.discovered.first {
                vm.serverURLInput = first.address.absoluteString
            }
        }
        // Discovery usually completes AFTER the view appears (it races the Local
        // Network permission prompt), so fill the URL in when it lands.
        .onChange(of: deps.lanDiscovery.discovered.first?.address) { _, address in
            if let address, let vm = viewModel, vm.serverURLInput.isEmpty {
                vm.serverURLInput = address.absoluteString
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            Group {
                switch vm.mode {
                case .password:
                    AuthScreenScaffold { card(vm: vm) }
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
            AuthScreenScaffold { LoginCardLoadingSkeleton() }
        }
    }

    @ViewBuilder
    private func card(vm: LoginViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: Space.s22) {
            AuthBrandHeader(
                icon: "hexagon.fill",
                title: "Parallax",
                subtitle: "Sign in to your Jellyfin server"
            )

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

            // Field stack
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
                    }
                }
            }
            .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))

            if let error = vm.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Connect (solid primary) — needs all three fields before it's tappable.
            Button {
                Task { if await vm.signIn() { await handleSuccess() } }
            } label: {
                Group {
                    if vm.isWorking { ProgressView().tint(Color.buttonLabel) }
                    else { Text("Connect").font(.headline) }
                }
                .frame(maxWidth: .infinity).frame(height: controlHeight)
            }
            .foregroundStyle(Color.buttonLabel)
            .background(Color.buttonFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .opacity(vm.canSubmitPassword ? 1 : 0.4)
            .disabled(vm.isWorking || !vm.canSubmitPassword)

            // OR divider
            HStack(spacing: Space.s12) {
                Rectangle().fill(Color.separator).frame(height: 1)
                Text("OR").font(.caption.weight(.semibold)).foregroundStyle(Color.tertiaryLabel)
                Rectangle().fill(Color.separator).frame(height: 1)
            }

            // Quick Connect (glass) — needs a server URL to pair against.
            Button {
                withAnimation(.smooth) { vm.switchToQuickConnect() }
            } label: {
                Label("Use Quick Connect", systemImage: "bolt.fill")
                    .font(.headline).foregroundStyle(Color.label)
                    .frame(maxWidth: .infinity).frame(height: controlHeight)
            }
            .glassPanel(cornerRadius: Radius.field)
            .opacity(vm.canUseQuickConnect ? 1 : 0.4)
            .disabled(!vm.canUseQuickConnect)
        }
        .padding(32)
        .glassBar(cornerRadius: 26)
    }

    /// URL-shaped placeholders get auto-styled as blue links, which ignores `.tint`
    /// and `.foregroundStyle`. Feeding the example as an `AttributedString` with an
    /// explicit color renders it in the normal placeholder gray instead.
    private static var urlPrompt: Text {
        var prompt = AttributedString("https://jellyfin.example.com")
        prompt.foregroundColor = Color.tertiaryLabel
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
        .frame(height: controlHeight)
    }

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

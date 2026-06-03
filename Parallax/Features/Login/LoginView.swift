import SwiftUI
import ParallaxJellyfin

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
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
                    ScrollView {
                        card(vm: vm)
                            .frame(maxWidth: 444)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, Space.s18)
                            .padding(.vertical, Space.s40)
                    }
                case .quickConnect:
                    QuickConnectView(serverURLInput: vm.serverURLInput) {
                        vm.switchToPassword()
                    }
                }
            }
            // Identity tied to the mode so the swap is a real insert/remove that the
            // transition animates (a transition on a stable wrapper wouldn't fire);
            // driven by the withAnimation at the toggle sites.
            .id(vm.mode)
            .transition(.blurReplace)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func card(vm: LoginViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: Space.s22) {
            // Brand
            VStack(spacing: Space.s12) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.label)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "hexagon.fill")
                            .scaledFont(30, relativeTo: .title, weight: .semibold)
                            .foregroundStyle(Color.background)
                    }
                Text("Parallax")
                    .scaledFont(30, relativeTo: .title, weight: .bold)
                    .foregroundStyle(Color.label)
                Text("Sign in to your Jellyfin server")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            }

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
                    TextField("https://jellyfin.example.com", text: $vm.serverURLInput)
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

            // Connect (solid primary)
            Button {
                Task { if await vm.signIn() { handleSuccess() } }
            } label: {
                Group {
                    if vm.isWorking { ProgressView().tint(Color.buttonLabel) }
                    else { Text("Connect").font(.headline) }
                }
                .frame(maxWidth: .infinity).frame(height: controlHeight)
            }
            .foregroundStyle(Color.buttonLabel)
            .background(Color.buttonFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .disabled(vm.isWorking)

            // OR divider
            HStack(spacing: Space.s12) {
                Rectangle().fill(Color.separator).frame(height: 1)
                Text("OR").font(.caption.weight(.semibold)).foregroundStyle(Color.tertiaryLabel)
                Rectangle().fill(Color.separator).frame(height: 1)
            }

            // Quick Connect (glass)
            Button {
                withAnimation(.smooth) { vm.switchToQuickConnect() }
            } label: {
                Label("Use Quick Connect", systemImage: "bolt.fill")
                    .font(.headline).foregroundStyle(Color.label)
                    .frame(maxWidth: .infinity).frame(height: controlHeight)
            }
            .glassPanel(cornerRadius: Radius.field)
        }
        .padding(32)
        .glassBar(cornerRadius: 26)
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

    private func handleSuccess() {
        if isPresented { dismiss() } else { router.goToHome() }
    }
}

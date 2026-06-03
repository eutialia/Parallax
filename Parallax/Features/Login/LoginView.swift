import SwiftUI
import ParallaxJellyfin

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: LoginViewModel?
    @State private var showPassword = false

    var body: some View {
        ZStack {
            Color.background.ignoresSafeArea()
            content
        }
        .task {
            if viewModel == nil {
                viewModel = LoginViewModel(sessionManager: deps.sessionManager)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.label)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "hexagon.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Color.background)
                    }
                Text("Parallax")
                    .font(.system(size: 30, weight: .bold))
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
                .frame(maxWidth: .infinity).frame(height: 50)
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
                vm.switchToQuickConnect()
            } label: {
                Label("Use Quick Connect", systemImage: "bolt.fill")
                    .font(.headline).foregroundStyle(Color.label)
                    .frame(maxWidth: .infinity).frame(height: 48)
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
        .frame(height: 50)
    }

    private func handleSuccess() {
        if isPresented { dismiss() } else { router.goToHome() }
    }
}

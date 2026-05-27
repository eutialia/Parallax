import SwiftUI
import ParallaxJellyfin

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: LoginViewModel?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sign in to Jellyfin")
        }
        .task {
            if viewModel == nil {
                viewModel = LoginViewModel(sessionManager: deps.sessionManager, router: router)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            switch vm.mode {
            case .password:
                passwordForm(vm: vm)
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
    private func passwordForm(vm: LoginViewModel) -> some View {
        @Bindable var vm = vm
        Form {
            Section("Server") {
                TextField("https://jellyfin.example.com", text: $vm.serverURLInput)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Account") {
                TextField("Username", text: $vm.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $vm.password)
            }
            if let error = vm.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button {
                    Task {
                        if await vm.signIn() {
                            dismiss()
                        }
                    }
                } label: {
                    if vm.isWorking { ProgressView() } else { Text("Sign In") }
                }
                .disabled(vm.isWorking)

                Button("Use Quick Connect instead") {
                    vm.switchToQuickConnect()
                }
            }
        }
    }
}

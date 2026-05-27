import SwiftUI

struct QuickConnectView: View {
    let serverURLInput: String
    let onSwitchToPassword: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: QuickConnectViewModel?

    var body: some View {
        VStack(spacing: 24) {
            content
            Button("Use username and password instead") {
                viewModel?.cancel()
                onSwitchToPassword()
            }
            .padding(.top, 16)
        }
        .padding()
        .task {
            if viewModel == nil {
                let vm = QuickConnectViewModel(sessionManager: deps.sessionManager, router: router)
                viewModel = vm
                vm.start(serverURLInput: serverURLInput)
            }
        }
        .onDisappear {
            viewModel?.cancel()
        }
        .onChange(of: viewModel?.didSignIn ?? false) { _, newValue in
            if newValue { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            switch vm.uiState {
            case .idle, .starting, .awaitingCode:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Requesting a pairing code…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .showingCode(let code):
                VStack(spacing: 16) {
                    Text("Open Jellyfin on the web, go to your user menu → Quick Connect, and enter this code:")
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.tertiary, in: .rect(cornerRadius: 16))
                    ProgressView()
                    Text("Waiting for approval…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .signingIn:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Signing you in…")
                }
            case .failure(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(message)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        vm.start(serverURLInput: serverURLInput)
                    }
                }
            }
        } else {
            ProgressView()
        }
    }
}

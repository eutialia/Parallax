import SwiftUI

struct QuickConnectView: View {
    let serverURLInput: String
    let onSwitchToPassword: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: QuickConnectViewModel?
    @State private var retryToken: Int = 0

    var body: some View {
        VStack(spacing: 24) {
            content
            Button("Use username and password instead") {
                onSwitchToPassword()
            }
            .padding(.top, 16)
        }
        .padding()
        .task(id: retryToken) {
            // .task(id:) cancels the previous Task and starts a new one each
            // time the id changes, so the stream lifetime is bound to view
            // identity — no manual cancel() or onDisappear plumbing needed.
            if viewModel == nil {
                viewModel = QuickConnectViewModel(sessionManager: deps.sessionManager)
            }
            await viewModel?.consume(serverURLInput: serverURLInput)
        }
        .onChange(of: viewModel?.didSignIn ?? false) { _, newValue in
            if newValue { handleSuccess() }
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
                        retryToken &+= 1
                    }
                }
            }
        } else {
            ProgressView()
        }
    }

    private func handleSuccess() {
        if isPresented {
            dismiss()
        } else {
            router.goToHome()
        }
    }
}

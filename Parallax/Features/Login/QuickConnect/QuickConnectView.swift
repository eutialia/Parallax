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
            HStack {
                Button {
                    withAnimation(.smooth) { onSwitchToPassword() }
                } label: {
                    Label("Back", systemImage: "chevron.left").font(.body.weight(.medium))
                }
                .foregroundStyle(Color.label)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            Button("Use username and password instead") {
                withAnimation(.smooth) { onSwitchToPassword() }
            }
            .font(.subheadline)
            .foregroundStyle(Color.secondaryLabel)
        }
        // Same centered column as the password card so the Back button aligns to the
        // content edge (not the raw sheet corner) and clears the grabber.
        .frame(maxWidth: 444)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.s18)
        .padding(.vertical, Space.s40)
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
                VStack(spacing: Space.s12) {
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
                        .scaledFont(56, relativeTo: .largeTitle, weight: .bold, design: .monospaced)
                        .tracking(8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.tertiary, in: .rect(cornerRadius: 16))
                    ProgressView()
                    Text("Waiting for approval…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .signingIn:
                VStack(spacing: Space.s12) {
                    ProgressView()
                    Text("Signing you in…")
                }
            case .failure(let message):
                VStack(spacing: Space.s12) {
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

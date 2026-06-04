import SwiftUI
import ParallaxJellyfin

struct QuickConnectView: View {
    let serverURLInput: String
    let onSwitchToPassword: () -> Void
    /// Reported up to `LoginView` so a successful pair runs the same success path as a
    /// password sign-in (router update at the root, or pop + refresh inside settings).
    let onSignedIn: () -> Void

    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: QuickConnectViewModel?
    @State private var retryToken: Int = 0
    /// Matches the sign-in card's control height so the bottom switch button lines up
    /// with the "Use Quick Connect" button it toggles against.
    @ScaledMetric(relativeTo: .headline) private var controlHeight: CGFloat = 50

    var body: some View {
        AuthScreenScaffold { card }
            .task(id: retryToken) {
                // .task(id:) cancels the previous Task and starts a new one each time the
                // id changes, so the stream lifetime is bound to view identity — no manual
                // cancel() or onDisappear plumbing needed.
                if viewModel == nil {
                    viewModel = QuickConnectViewModel(sessionManager: deps.sessionManager)
                }
                await viewModel?.consume(serverURLInput: serverURLInput)
            }
            .onChange(of: viewModel?.didSignIn ?? false) { _, signedIn in
                if signedIn { onSignedIn() }
            }
    }

    /// Same glass card + 32pt padding as the sign-in card, so toggling between the two
    /// modes keeps the box in the same place. Everything (header, code, status, switch
    /// button) lives inside the box.
    private var card: some View {
        VStack(spacing: Space.s22) {
            AuthBrandHeader(
                icon: "bolt.fill",
                title: "Quick Connect",
                subtitle: "Approve this device from a Jellyfin session that's already signed in"
            )
            content
            // Switch back to password — occupies the exact slot the sign-in card's "Use
            // Quick Connect" button does, so toggling between the two happens in one place.
            Button {
                withAnimation(.smooth) { onSwitchToPassword() }
            } label: {
                Label("Use password instead", systemImage: "person.fill")
                    .font(.headline).foregroundStyle(Color.label)
                    .frame(maxWidth: .infinity).frame(height: controlHeight)
            }
            .glassPanel(cornerRadius: Radius.field)
        }
        .padding(32)
        .glassBar(cornerRadius: 26)
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            switch vm.uiState {
            case .idle, .starting, .awaitingCode:
                QuickConnectLoadingSkeleton()
            case .showingCode(let code):
                VStack(spacing: 16) {
                    Text("Open Jellyfin on the web, go to your user menu → Quick Connect, and enter this code:")
                        .font(.callout)
                        .foregroundStyle(Color.secondaryLabel)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .scaledFont(56, relativeTo: .largeTitle, weight: .bold, design: .monospaced)
                        .tracking(8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.tertiary, in: .rect(cornerRadius: 16))
                    waitingIndicator
                }
            case .signingIn:
                VStack(spacing: Space.s12) {
                    QuickConnectLoadingSkeleton()
                    Text("Signing you in…")
                        .font(.callout)
                        .foregroundStyle(Color.secondaryLabel)
                }
            case .failure(let message):
                VStack(spacing: Space.s12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.label)
                    Button("Try again") { retryToken &+= 1 }
                }
            }
        } else {
            QuickConnectLoadingSkeleton()
        }
    }

    /// Subtle "still polling" cue: a shimmer sweep across the status pill, matching the
    /// app's in-progress visual language (this screen polls the server on a timer; the
    /// shimmer stands in for the removed spinner). Static under Reduce Motion via
    /// `skeletonShimmer`.
    private var waitingIndicator: some View {
        Text("Waiting for approval…")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.secondaryLabel)
            .padding(.horizontal, Space.s14)
            .padding(.vertical, Space.s8)
            .background(Color.fill, in: Capsule())
            .skeletonShimmer()
    }
}

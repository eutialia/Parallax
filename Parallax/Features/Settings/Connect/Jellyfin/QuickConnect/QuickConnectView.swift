import SwiftUI
import ParallaxJellyfin

struct QuickConnectView: View {
    let serverURLInput: String
    let onSwitchToPassword: () -> Void
    /// Reported up to `LoginView` so a successful pair runs the same success path as a
    /// password sign-in (router update at the root, or pop + refresh inside settings).
    let onSignedIn: () -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: QuickConnectViewModel?
    @State private var retryToken: Int = 0

    /// Body only — the brand mark + scaffold are supplied by the host (`LoginView` in settings, the
    /// source picker when logged out), so the shared "Parallax" mark stays put across the password
    /// ↔ Quick Connect swap. The subtitle, code/status, and switch button sit directly on the floor.
    var body: some View {
        VStack(spacing: Space.s22) {
            AuthSubtitle("Approve this device from a Jellyfin session that's already signed in")
            content
            // Switch back to password — occupies the exact slot the sign-in body's "Use
            // Quick Connect" button does, so toggling between the two happens in one place.
            Button {
                withAnimation(reduceMotion ? nil : .smooth) { onSwitchToPassword() }
            } label: {
                Label("Use password instead", systemImage: "person.fill")
                    .formActionLabel()
            }
            .formActionButton(.glass)
        }
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

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            switch vm.uiState {
            case .idle, .starting, .awaitingCode:
                VStack(spacing: Space.s12) {
                    QuickConnectLoadingSkeleton()
                    Text("Getting a code from your server…")
                        .font(.callout)
                        .foregroundStyle(Color.secondaryLabel)
                }
            case .showingCode(let code):
                VStack(spacing: Space.s16) {
                    Text("Open Jellyfin on the web, go to your user menu → Quick Connect, and enter this code:")
                        .font(.callout)
                        .foregroundStyle(Color.secondaryLabel)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .scaledFont(56, relativeTo: .largeTitle, weight: .bold, design: .monospaced)
                        .tracking(8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        // `.tracking` adds a trailing 8pt AFTER the last digit, nudging the code ~4pt
                        // right of the chip's optical center. Cancel just the trailing gap; keep the tracking.
                        .padding(.trailing, -8)
                        .padding(.horizontal, Space.s22)
                        .padding(.vertical, Space.s16)
                        .background(Color.surface, in: .rect(cornerRadius: Radius.card))
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
                        .foregroundStyle(Color.red)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.label)
                    Button {
                        retryToken &+= 1
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .formActionLabel()
                    }
                    .formActionButton(.glass)
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

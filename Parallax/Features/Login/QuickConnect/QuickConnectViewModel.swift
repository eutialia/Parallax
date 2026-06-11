import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class QuickConnectViewModel {
    enum UIState {
        case idle
        case starting
        case awaitingCode
        case showingCode(String)
        case signingIn
        case failure(String)
    }

    var uiState: UIState = .idle
    var didSignIn: Bool = false

    private let sessionManager: SessionManager

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    /// Drives the Quick Connect stream to completion. Designed to be invoked
    /// from a SwiftUI `.task(id:)` so the Task's cancellation lifetime is tied
    /// to the view's identity — no manual cancel(), no strong-self retention.
    func consume(serverURLInput: String) async {
        guard let url = LoginViewModel.normalize(serverURLInput) else {
            uiState = .failure("That server URL doesn't look right. Switch back to password sign-in to fix it.")
            return
        }
        uiState = .starting
        didSignIn = false
        for await status in await sessionManager.signInWithQuickConnect(server: url) {
            apply(status)
        }
    }

    private func apply(_ status: QuickConnectStatus) {
        switch status {
        case .waitingForCode:
            uiState = .awaitingCode
        case .polling(let code):
            uiState = .showingCode(code)
        case .signedIn:
            uiState = .signingIn
            didSignIn = true
        case .expired:
            uiState = .failure("The pairing code expired before this device was approved.")
        case .failed(let reason):
            uiState = .failure(reason)
        }
    }
}

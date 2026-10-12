import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
public final class QuickConnectViewModel {
    public enum UIState: Equatable {
        case idle
        case starting
        case awaitingCode
        case showingCode(String)
        case signingIn
        case failure(String)
    }

    public private(set) var uiState: UIState = .idle

    private let sessionManager: SessionManager
    /// Runs once the server has approved this device and the session is saved: the same success
    /// path a password sign-in takes.
    private let onSignedIn: () async -> Void

    init(sessionManager: SessionManager, onSignedIn: @escaping () async -> Void) {
        self.sessionManager = sessionManager
        self.onSignedIn = onSignedIn
    }

    /// Drives the Quick Connect stream to completion. Designed to be invoked
    /// from a SwiftUI `.task(id:)` so the Task's cancellation lifetime is tied
    /// to the view's identity — no manual cancel(), no strong-self retention.
    public func consume(serverURLInput: String) async {
        guard let url = LoginViewModel.normalize(serverURLInput) else {
            uiState = .failure("That server URL doesn't look right. Switch back to password sign-in to fix it.")
            return
        }
        uiState = .starting
        for await status in await sessionManager.signInWithQuickConnect(server: url) {
            apply(status)
            if case .signedIn = status { await onSignedIn() }
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
        case .expired:
            uiState = .failure("The pairing code expired before this device was approved.")
        case .failed(let reason):
            uiState = .failure(reason)
        }
    }
}

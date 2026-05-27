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

    private let sessionManager: SessionManager
    private let router: AppRouter
    private var streamTask: Task<Void, Never>?

    init(sessionManager: SessionManager, router: AppRouter) {
        self.sessionManager = sessionManager
        self.router = router
    }

    func start(serverURLInput: String) {
        guard let url = LoginViewModel.normalize(serverURLInput) else {
            uiState = .failure("Enter a valid server URL on the previous screen first.")
            return
        }
        cancel()
        uiState = .starting
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await status in await self.sessionManager.signInWithQuickConnect(server: url) {
                await MainActor.run { self.apply(status) }
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func apply(_ status: QuickConnectStatus) {
        switch status {
        case .waitingForCode:
            uiState = .awaitingCode
        case .polling(let code):
            uiState = .showingCode(code)
        case .signedIn:
            uiState = .signingIn
            router.goToHome()
        case .rejected:
            uiState = .failure("The server rejected the pairing request. Check the URL and try again.")
        case .expired:
            uiState = .failure("The pairing code expired before you authorised it. Try again.")
        }
    }


}

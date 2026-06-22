import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class LoginViewModel {
    enum Mode { case password, quickConnect }

    var serverURLInput: String = ""
    var username: String = ""
    var password: String = ""
    var isWorking: Bool = false
    var errorMessage: String?
    var mode: Mode = .password

    private let sessionManager: SessionManager

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    /// Connect needs all three fields. (Jellyfin allows blank passwords, but the
    /// form gates on a filled one as the user's explicit "I'm ready" signal.)
    var canSubmitPassword: Bool {
        hasServerURL
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    /// Quick Connect only needs to know which server to pair with.
    var canUseQuickConnect: Bool { hasServerURL }

    private var hasServerURL: Bool {
        !serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns true on successful sign-in. The caller decides what to do with the
    /// success — `LoginView` either drives the router (logged-out root) or runs the
    /// `onSignedIn` closure (settings add-server flow).
    @discardableResult
    func signIn() async -> Bool {
        errorMessage = nil
        guard let url = Self.normalize(serverURLInput) else {
            errorMessage = "That server URL doesn't look right. Check it and try again."
            return false
        }
        guard !username.isEmpty else {
            errorMessage = "Enter your username."
            return false
        }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await sessionManager.signIn(server: url, username: username, password: password)
            return true
        } catch let error as AppError {
            Log.auth.error("LoginView signIn failed: \(error.userMessage)")
            errorMessage = error.userMessage
            return false
        } catch {
            Log.auth.error("LoginView signIn unexpected: \(String(describing: type(of: error)))")
            errorMessage = "Couldn't sign in. Try again."
            return false
        }
    }

    func switchToQuickConnect() {
        mode = .quickConnect
    }

    func switchToPassword() {
        mode = .password
    }

    static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }
}

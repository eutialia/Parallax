import Foundation
import Observation
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

    /// Returns true on successful sign-in. The caller decides what to do with
    /// the success — dismiss the sheet if presented, or push the router to
    /// .home if running as the root view.
    @discardableResult
    func signIn() async -> Bool {
        errorMessage = nil
        guard let url = Self.normalize(serverURLInput) else {
            errorMessage = "Enter a valid server URL."
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
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Something went wrong."
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

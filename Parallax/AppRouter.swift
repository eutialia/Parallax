import Foundation
import Observation
import ParallaxJellyfin

@Observable
@MainActor
final class AppRouter {
    enum Destination: Hashable {
        case login
        case home
    }

    var destination: Destination = .login

    func updateForCurrentSession(_ session: Session?) {
        destination = (session == nil) ? .login : .home
    }

    func goToLogin() {
        destination = .login
    }

    func goToHome() {
        destination = .home
    }
}

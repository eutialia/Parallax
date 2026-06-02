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

    /// Identity of the active server. `RootTabView` keys its per-server view
    /// remount on this so a server switch reloads Home/Library/Search. It lives
    /// here (not in `RootTabView` `@State`) because `ServerStore` is an actor
    /// with no SwiftUI observation: the app-side router is the single source of
    /// truth, updated by every site that changes the active session.
    var activeServerID: ServerID?

    func updateForCurrentSession(_ session: Session?) {
        destination = (session == nil) ? .login : .home
        activeServerID = session?.id
    }

    func goToLogin() {
        destination = .login
        activeServerID = nil
    }

    func goToHome() {
        destination = .home
    }
}

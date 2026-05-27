import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        switch router.destination {
        case .login:
            LoginView()
        case .home:
            ServerListView()
        }
    }
}

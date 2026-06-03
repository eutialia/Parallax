import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            switch router.destination {
            case .login:
                LoginView()
            case .home:
                RootTabView()
            }
        }
        // Monochrome chrome: no brand accent anywhere. This overrides the system
        // accent for every control (selection, toggles, links) beneath the root.
        .tint(Color.label)
    }
}

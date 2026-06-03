import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlaybackPresenter.self) private var playback

    var body: some View {
        @Bindable var playback = playback
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
        // The player lives at the stable root — ABOVE RootTabView's
        // `.id(activeServerID)` remount — so a server switch can't force-dismiss it
        // and then re-present the previous server's player from a stale request.
        .fullScreenCover(item: $playback.request) { request in
            PlayerView(itemID: request.itemID, session: request.session)
        }
        // Switching / adding / signing out a server closes any open player: its
        // content belongs to the previous server's session.
        .onChange(of: router.activeServerID) { _, _ in
            playback.request = nil
        }
    }
}

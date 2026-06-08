import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlaybackPresenter.self) private var playback

    var body: some View {
        @Bindable var playback = playback
        @Bindable var router = router
        Group {
            switch router.destination {
            case .bootstrapping, .home:
                // One `RootTabView` for bootstrap + home so finishing `ServerStore.load()`
                // doesn't tear down tabs mid-flight (that cancelled Home's first request).
                #if os(tvOS)
                FocusRootView()
                #else
                RootTabView()
                #endif
            case .login:
                // Login sits outside `RootTabView`, so it carries its own floor.
                // (`.containerBackground(for: .window)` is macOS-only; tabs use `.tabView`.)
                LoginView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.background)
            }
        }
        // Monochrome chrome: no brand accent anywhere. This overrides the system
        // accent for every control (selection, toggles, links) beneath the root.
        .tint(Color.label)
        // The floating settings panel lives at the stable root — ABOVE RootTabView's
        // `.id(activeServerID)` remount — so switching/adding a server from inside it
        // (which re-points the router) doesn't tear the open panel down.
        #if !os(tvOS)
        .sheet(isPresented: $router.presentingSettings) {
            SettingsView()
        }
        #endif
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

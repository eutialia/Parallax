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
                //
                // The single screen floor lives HERE, behind the whole tab host — not sprayed
                // per-screen inside each NavigationStack. It sits under the sidebar/tab-bar glass
                // too, so the chrome reads as a solid tinted bar (there's nothing but a flat color
                // to refract anyway). Content stacks on top of this one constant floor, which is
                // what lets the tvOS detail crossfade dissolve over a background that never moves.
                Group {
                    #if os(tvOS)
                    FocusRootView()
                    #else
                    RootTabView()
                    #endif
                }
                .background(Color.background.ignoresSafeArea())
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
        // iPad's settings sheet lives at the stable root — ABOVE RootTabView's
        // `.id(activeServerID)` remount — so switching/adding a server from inside it (which
        // re-points the router) doesn't tear the open panel down. iPhone uses a Settings tab
        // instead (see RootTabView), so this only ever fires on iPad's sidebar-footer action.
        #if !os(tvOS)
        .sheet(isPresented: $router.presentingSettings) {
            SettingsView(isModal: true)
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

import SwiftUI
import ParallaxJellyfin

/// The logged-out entry point, folded onto the same surface as Settings: a `SettingsScaffold` (brand
/// rail) hosting a CONNECT group with the two source choices. Tapping a choice PUSHES its add flow
/// (Jellyfin sign-in / SMB connect) on this screen's own `NavigationStack` — the same push model
/// Settings uses for "Add Server", so logged-out and signed-in read identically. There's no in-place
/// slide any more, so the old chromeless/cover/persisted-VM machinery is gone.
///
/// A successful Jellyfin sign-in (`LoginView` with `onSignedIn` nil drives the router itself) or a first
/// SMB add routes to home, which unmounts this whole view.
struct ConnectSourceView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var path: [ConnectRoute] = []

    private enum ConnectRoute: Hashable { case jellyfin, smb }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsScaffold(brandSubtitle: "Choose how to connect") {
                SettingsGroup {
                    SettingsListRow(
                        image: "JellyfinGlyph",
                        title: "Jellyfin Server",
                        subtitle: "Sign in to your media server",
                        accessory: .chevron
                    ) { path.append(.jellyfin) }
                    SettingsListRow(
                        systemImage: "externaldrive.connected.to.line.below.fill",
                        title: "SMB / Network Share",
                        subtitle: "Connect to a network share",
                        accessory: .chevron
                    ) { path.append(.smb) }
                }
            }
            .navigationDestination(for: ConnectRoute.self) { route in
                switch route {
                case .jellyfin:
                    LoginView()
                        .navigationTitle("Sign In")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                case .smb:
                    SMBLoginView(onAdded: { routeAfterSMBAdd() })
                        .navigationTitle("Add SMB Server")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
            }
        }
        // tvOS: pin the app icon to the left, outside the stack, so it stays put while pushing into
        // the Jellyfin / SMB add flows. No-op on iOS.
        .tvSettingsBrandRail()
        .background(Color.background.ignoresSafeArea())
    }

    /// A first SMB source was saved while logged out: route to SMB-only home (no Jellyfin session),
    /// which unmounts this view and rearms the launch reveal over the first Home boot — the same path a
    /// Jellyfin sign-in takes. The router falls back to SMB-only home when there's an auxiliary source
    /// but no active session.
    private func routeAfterSMBAdd() {
        Task {
            router.updateForSources(
                activeSession: await deps.serverStore.active,
                hasAuxiliarySources: await deps.serverStore.hasSMBServers
            )
        }
    }
}

/// The logged-out root. Hosts `ConnectSourceView` full-screen on every platform — there's no signed-in
/// state behind it to peek at, so no sheet idiom; the scaffold gives the same flat settings look
/// whether you're signed in or out.
struct LoggedOutRootView: View {
    var body: some View {
        ConnectSourceView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
/// Env-free render of the logged-out Connect surface — the real `ConnectSourceView` reads
/// `AppDependencies`/`AppRouter`, so it can't render in a preview. Mirrors the body's scaffold + group.
#Preview("Connect · logged out", traits: .fixedLayout(width: 1920, height: 1080)) {
    SettingsScaffold(brandSubtitle: "Choose how to connect") {
        SettingsGroup {
            SettingsListRow(image: "JellyfinGlyph", title: "Jellyfin Server", subtitle: "Sign in to your media server", accessory: .chevron) {}
            SettingsListRow(systemImage: "externaldrive.connected.to.line.below.fill", title: "SMB / Network Share", subtitle: "Connect to a network share", accessory: .chevron) {}
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif

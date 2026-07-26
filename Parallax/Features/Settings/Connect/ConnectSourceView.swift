import SwiftUI
import os
import ParallaxCore
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
    /// Servers Parallax still has on file but can no longer sign requests for. Non-empty when the
    /// LAST source lost its session — a revoked token, or a Keychain slot that didn't survive.
    @State private var signedOutServers: [SignedOutServerRow] = []

    private enum ConnectRoute: Hashable {
        case jellyfin
        /// Re-authenticating a known server; payload is its address to pre-fill.
        case signInAgain(String)
        case smb
    }

    var body: some View {
        NavigationStack(path: $path) {
            // The subtitle follows the actual situation. "Choose how to connect" reads as a
            // first-run greeting; arriving here because a token was revoked isn't first-run, and
            // being greeted as though you'd never set anything up is the wrong tone for it.
            SettingsScaffold(brandSubtitle: signedOutServers.isEmpty ? "Choose how to connect" : "Sign back in, or add another source") {
                // Above the "add something" choices, because this isn't adding anything: it's the
                // server you already had, one tap from working again. Landing here after a token
                // was revoked and being offered only a blank "Jellyfin Server" form would mean
                // retyping an address the app still has on disk.
                if !signedOutServers.isEmpty {
                    SettingsGroup(
                        title: "Signed Out",
                        footer: "Parallax still has these servers, but not a valid sign-in for them."
                    ) {
                        ForEach(signedOutServers) { server in
                            SignedOutServerButton(
                                server: server,
                                onSignIn: { path.append(.signInAgain($0.serverURL)) },
                                onRemove: { id in Task { await removeSignedOutServer(id) } }
                            )
                        }
                    }
                }
                ServerTypeChoiceGroup(
                    onChooseJellyfin: { path.append(.jellyfin) },
                    onChooseSMB: { path.append(.smb) }
                )
            }
            .navigationDestination(for: ConnectRoute.self) { route in
                switch route {
                case .jellyfin:
                    LoginView()
                        .navigationTitle("Jellyfin")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                case .signInAgain(let serverURL):
                    // `onSignedIn` stays nil, as on the add path: LoginView drives the router
                    // itself, and a successful sign-in replaces the persisted row in place
                    // (deterministic server id) rather than adding a duplicate.
                    LoginView(prefilledServerURL: serverURL)
                        .navigationTitle("Sign In Again")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                case .smb:
                    SMBLoginView(onAdded: { routeAfterSMBAdd() })
                        .navigationTitle("Network Share")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
            }
        }
        .task { await loadSignedOutServers() }
        // tvOS: pin the app icon to the left, outside the stack, so it stays put while pushing into
        // the Jellyfin / SMB add flows. No-op on iOS. The surface color is owned by whoever wraps this
        // per platform — `TVSettingsRail` on tvOS, the `SettingsScaffold` it hosts on iOS — so this view
        // paints none of its own.
        .tvSettingsBrandRail()
    }

    /// A first SMB source was saved while logged out: route to SMB-only home (no Jellyfin session),
    /// which unmounts this view and rearms the launch reveal over the first Home boot — the same path a
    /// Jellyfin sign-in takes. The router falls back to SMB-only home when there's an auxiliary source
    /// but no active session.
    private func routeAfterSMBAdd() {
        Task {
            router.updateForSources(await deps.serverStore.sourceSnapshot)
        }
    }

    private func loadSignedOutServers() async {
        signedOutServers = await deps.serverStore.signedOutJellyfinServers.compactMap(SignedOutServerRow.init)
    }

    /// Discards a signed-out row from here. The login/home boundary can't move (a signed-out server
    /// contributes no source, and we're already on the far side of it), but the router is still
    /// re-pointed: `sourceSetIdentity` fingerprints every persisted row, signed-out ones included,
    /// so skipping it would leave the roots' reload token naming a server that no longer exists.
    /// Re-reads the list so the group empties (and disappears) once the last row goes.
    private func removeSignedOutServer(_ id: ServerID) async {
        do {
            try await deps.serverStore.remove(id)
        } catch {
            Log.persistence.error("Connect removeSignedOutServer failed for \(id.rawValue): \(error.localizedDescription)")
        }
        router.updateForSources(await deps.serverStore.sourceSnapshot)
        await loadSignedOutServers()
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
/// Env-free renders of the logged-out Connect surface — the real `ConnectSourceView` reads
/// `AppDependencies`/`AppRouter`, so it can't render in a preview. Mirrors the body's scaffold +
/// groups.
private struct ConnectPreview: View {
    var signedOut: [SignedOutServerRow] = []

    var body: some View {
        SettingsScaffold(brandSubtitle: signedOut.isEmpty ? "Choose how to connect" : "Sign back in, or add another source") {
            if !signedOut.isEmpty {
                SettingsGroup(
                    title: "Signed Out",
                    footer: "Parallax still has these servers, but not a valid sign-in for them."
                ) {
                    ForEach(signedOut) { server in
                        SignedOutServerButton(server: server, onSignIn: { _ in }, onRemove: { _ in })
                    }
                }
            }
            SettingsGroup(footer: "More server types are on the way.") {
                SettingsListRow(image: "JellyfinGlyph", iconSize: 22, title: "Jellyfin Server", subtitle: "Sign in to your media server", accessory: .chevron) {}
                SettingsListRow(systemImage: "externaldrive.badge.wifi", iconSize: 22, title: "Network Share", subtitle: "Connect over SMB to a shared folder", accessory: .chevron) {}
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenFloor()
    }

    static func row(_ name: String, _ host: String) -> SignedOutServerRow? {
        SignedOutServerRow(PersistedServer(
            id: ServerID(rawValue: host),
            kind: .jellyfin(JellyfinServerData(
                serverURL: URL(string: "https://\(host):8096")!,
                serverName: name,
                user: UserSnapshot(id: "u", name: "alice", serverLastUpdatedAt: nil)
            ))
        ))
    }
}

#Preview("Connect · logged out", traits: .fixedLayout(width: 1920, height: 1080)) {
    ConnectPreview().preferredColorScheme(.dark)
}

/// The state a revoked token lands you in when it was your ONLY source: the server you already had
/// is offered first, one tap from working again, instead of a blank form that makes you retype an
/// address the app still has on disk.
#Preview("Connect · signed out server", traits: .fixedLayout(width: 540, height: 980)) {
    ConnectPreview(signedOut: [ConnectPreview.row("home-jellyfin", "jellyfin.example.lan")].compactMap { $0 })
}
#endif

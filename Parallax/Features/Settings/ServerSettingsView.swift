import SwiftUI
import ParallaxJellyfin

/// Per-server settings detail — pushed from a server row in `SettingsView`. The VM-wiring shell: it maps
/// the `Session` + `SettingsViewModel` into plain values + callbacks for `ServerSettingsContentView`, so
/// there's a single implementation of sign-out with its router side effects. Mirrors the `SettingsView` /
/// `SettingsContentView` split, keeping the presentation pure and previewable.
struct ServerSettingsView: View {
    let session: Session
    let vm: SettingsViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ServerSettingsContentView(
            serverName: session.serverName,
            host: session.displayHost,
            userName: session.user.name,
            signOutError: vm.signOutErrorMessage,
            onSignOut: {
                Task {
                    await vm.signOut(session)
                    // On success pop back — this server is gone. Always dismiss the detail: if that was
                    // the last SOURCE the router routed to login and tore the panel down (dismiss on the
                    // vanishing sheet is a harmless no-op); but if an SMB source remains the router falls
                    // back to SMB-only home and KEEPS the panel, so without this pop the user would be
                    // stranded on a ghost page for a server that no longer exists. On failure stay so the
                    // shared vm's error message shows.
                    if vm.signOutErrorMessage == nil { dismiss() }
                }
            }
        )
    }
}

/// Pure, previewable presentation of the per-server detail: the server subject hero plus the "This Server"
/// actions. Holds no view model — the parent maps VM state into plain values + callbacks, so this renders
/// in a `#Preview` with mock data (the real screen, minus the network).
struct ServerSettingsContentView: View {
    let serverName: String
    let host: String
    let userName: String
    var signOutError: String? = nil
    let onSignOut: () -> Void

    var body: some View {
        SettingsScaffold(title: serverName, showsBrand: false) {
            // iOS leads with the server itself as the screen's subject (the app brand is suppressed above);
            // tvOS keeps the compact identity card since its rail shows only the name, not the host.
            #if os(tvOS)
            header
            #else
            hero
            #endif
            SettingsGroup(title: "This Server") {
                SettingsListRow(
                    systemImage: "person",
                    title: "Signed in as",
                    value: userName
                )
                SettingsListRow(
                    systemImage: "rectangle.portrait.and.arrow.right",
                    title: "Sign Out",
                    role: .destructive,
                    action: onSignOut
                )
            }
            if let signOutError {
                Text(signOutError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s14)
            }
        }
        .navigationTitle(serverName)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    #if !os(tvOS)
    /// iOS subject hero: the server as the screen's headline, mirroring the settings root's centered brand
    /// lockup (icon over title) but server-specific. Replaces both the old identity card and the app brand.
    private var hero: some View {
        VStack(spacing: Space.s14) {
            IconTile(image: "JellyfinGlyph", size: 64, cornerRadius: Radius.field, glyphSize: 34)
            VStack(spacing: 4) {
                Text(serverName)
                    .scaledFont(28, relativeTo: .title, weight: .bold)
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(host)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Space.s8)
    }
    #else
    /// tvOS connected-server identity card — a flat surface panel (a header, not a list group). The rail
    /// shows only the server name, so this adds the host alongside it in the pill column.
    private var header: some View {
        HStack(spacing: Space.s14) {
            IconTile(image: "JellyfinGlyph", size: 52, cornerRadius: 14, glyphSize: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(serverName)
                    .font(.cardHeaderTitle)
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(host)
                    .font(.cardHeaderSubtitle)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s8)
        }
        .padding(Space.s18)
        .surfacePanel(cornerRadius: Radius.card)
    }
    #endif
}

#if DEBUG
#Preview("Server detail", traits: .fixedLayout(width: 1024, height: 900)) {
    NavigationStack {
        ServerSettingsContentView(
            serverName: "home-jellyfin",
            host: "jellyfin.example.lan",
            userName: "admin",
            onSignOut: {}
        )
    }
    .preferredColorScheme(.dark)
}
#endif

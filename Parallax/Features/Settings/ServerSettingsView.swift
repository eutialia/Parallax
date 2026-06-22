import SwiftUI
import ParallaxJellyfin

/// Per-server settings detail — pushed from a server row in `SettingsView`. A connected-server header
/// plus the "This Server" actions (make active, sign out). Uses the shared `SettingsScaffold` (brand
/// rail) + `SettingsGroup`/`SettingsListRow`, so it reads identically to the settings root.
///
/// Actions reuse `SettingsViewModel` (passed in from the panel) so there's a single implementation of
/// set-active / sign-out with their router side effects.
struct ServerSettingsView: View {
    let session: Session
    let vm: SettingsViewModel

    @Environment(\.dismiss) private var dismiss

    private var isActive: Bool { vm.activeID == session.id }

    var body: some View {
        SettingsScaffold(title: session.serverName) {
            header
            SettingsGroup(title: "This Server") {
                SettingsListRow(
                    systemImage: "person",
                    title: "Signed in as",
                    value: session.user.name
                )
                if !isActive {
                    SettingsListRow(
                        systemImage: "checkmark.circle",
                        title: "Make This Server Active"
                    ) {
                        Task { await vm.setActive(session.id) }
                    }
                }
                SettingsListRow(
                    systemImage: "rectangle.portrait.and.arrow.right",
                    title: "Sign Out",
                    role: .destructive
                ) {
                    Task {
                        await vm.signOut(session)
                        // On success pop back — this server is gone. Always dismiss the detail: if that
                        // was the last SOURCE the router routed to login and tore the panel down (dismiss
                        // on the vanishing sheet is a harmless no-op); but if an SMB source remains the
                        // router falls back to SMB-only home and KEEPS the panel, so without this pop the
                        // user would be stranded on a ghost page for a server that no longer exists. On
                        // failure stay so the shared vm's error message shows.
                        if vm.signOutErrorMessage == nil { dismiss() }
                    }
                }
            }
            if let message = vm.signOutErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s14)
            }
        }
        .navigationTitle(session.serverName)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    /// The connected-server identity card — a flat surface panel (a header, not a list group).
    private var header: some View {
        HStack(spacing: Space.s14) {
            IconTile(systemImage: "server.rack", size: 52, cornerRadius: 14, glyphSize: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.serverName)
                    .font(.cardHeaderTitle)
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(session.displayHost)
                    .font(.cardHeaderSubtitle)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s8)
            HStack(spacing: 6) {
                Circle().fill(isActive ? Color.ok : Color.tertiaryLabel).frame(width: 8, height: 8)
                Text(isActive ? "Active" : "Idle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.label)
            }
        }
        .padding(Space.s18)
        .surfacePanel(cornerRadius: Radius.card)
    }
}

import SwiftUI
import ParallaxJellyfin

/// Per-server settings detail — the design handoff's `screen-settings`. Pushed from a
/// server card in the floating `SettingsView`. This is the reuse-only build: a connected-
/// server header plus the "This Server" actions that already exist (make active, sign out).
/// The Playback section (engine / quality / bitrate / subtitle appearance), Quick Connect
/// authorizing, Manage Devices, and the live stats strip are deferred until their
/// settings/persistence plumbing lands.
///
/// Actions reuse `SettingsViewModel` (passed in from the panel) so there's a single
/// implementation of set-active / sign-out with their router side effects.
struct ServerSettingsView: View {
    let session: Session
    let vm: SettingsViewModel

    @Environment(\.dismiss) private var dismiss

    private var isActive: Bool { vm.activeID == session.id }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s22) {
                header
                section(title: "This Server") { thisServerCard }
                if let message = vm.signOutErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.s14)
                }
            }
            .padding(Space.s18)
            // Match the handoff's reading measure on wide (iPad) layouts, centered.
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(session.serverName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.s14) {
            IconTile(systemImage: "server.rack", size: 52, cornerRadius: 14, glyphSize: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.serverName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(session.displayHost)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s8)
            if isActive {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.label)
                }
            }
        }
        .padding(Space.s18)
        .glassBar(cornerRadius: Radius.card)
    }

    // MARK: - This Server

    private var thisServerCard: some View {
        VStack(spacing: 0) {
            SettingsRow(
                systemImage: "person",
                title: "Signed in as",
                value: session.user.name,
                showsChevron: false
            )
            if !isActive {
                rowSeparator
                SettingsRow(
                    systemImage: "checkmark.circle",
                    title: "Make This Server Active",
                    showsChevron: false
                ) {
                    Task { await vm.setActive(session.id) }
                }
            }
            rowSeparator
            SettingsRow(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: "Sign Out",
                showsChevron: false,
                role: .destructive
            ) {
                Task {
                    await vm.signOut(session)
                    // On success pop back to the list — unless that was the last server,
                    // in which case the router already routed to login and tore this whole
                    // panel down (calling dismiss() on the vanishing sheet would warn). On
                    // failure stay so the error message (surfaced by the shared vm) shows.
                    if vm.signOutErrorMessage == nil, !vm.sessions.isEmpty { dismiss() }
                }
            }
        }
        .glassPanel(cornerRadius: Radius.card)
    }

    // MARK: - Building blocks

    /// Section label + content, matching the handoff's uppercase group heading.
    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Color.secondaryLabel)
                .padding(.horizontal, Space.s14)
            content()
        }
    }

    /// Hairline between rows, inset to start past the icon tile (geometry owned by
    /// `SettingsRow`, so this stays correct if the tile size ever changes).
    private var rowSeparator: some View {
        Divider().padding(.leading, SettingsRow.separatorLeadingInset)
    }
}

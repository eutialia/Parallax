import SwiftUI
import ParallaxJellyfin

/// A signed-out Jellyfin server's row data — the persisted server survives, its session doesn't.
struct SignedOutServerRow: Identifiable {
    let id: ServerID
    let name: String
    /// Display host, matching `Session.displayHost` so a server reads identically signed-in and out.
    let host: String
    /// The full server address, used to pre-fill the sign-in form. Kept separate from `host`, which
    /// is display-only and drops the scheme and port — pre-filling with that would hand the user a
    /// URL that doesn't connect, which is worse than an empty field.
    let serverURL: String

    init?(_ server: PersistedServer) {
        guard case .jellyfin(let data) = server.kind else { return nil }
        id = server.id
        name = data.serverName
        host = data.serverURL.host() ?? data.serverName
        serverURL = data.serverURL.absoluteString
    }
}

/// One signed-out Jellyfin server row, with its sign-in-again / remove prompt.
///
/// Shared by Settings and the logged-out Connect screen, because a server can lose its session in
/// both places: revoked at runtime while you're browsing (`ServerStore.invalidateSession`), or
/// unreadable at launch (lost Keychain slot). If it was your ONLY source you're routed to Connect
/// and never see Settings at all — so without this on both surfaces the row you kept would be
/// invisible exactly when it's most needed, and the way back would be retyping the address.
///
/// Deliberately passive: a row that sits in a list, with the prompt appearing only on tap. Nothing
/// auto-presents and nothing is modal until you ask — a dead token is a thing to fix when you feel
/// like it, not an interruption, and any other servers keep working meanwhile.
///
/// A single ROW rather than the whole `ForEach`, so it stays one declared subview per server:
/// `SettingsGroup` interleaves its hairlines via `Group(subviews:)`, which flattens `ForEach` but
/// treats a custom view as one opaque leaf — a wrapper here would collapse every signed-out server
/// into a single undivided block.
struct SignedOutServerButton: View {
    let server: SignedOutServerRow
    let onSignIn: (SignedOutServerRow) -> Void
    let onRemove: (ServerID) -> Void

    /// Per-row, so the row owns its own presentation instead of the parent tracking which row is
    /// prompting and every row comparing ids against it.
    @State private var isPrompting = false

    var body: some View {
        Button { isPrompting = true } label: {
            SettingsRowLabel(
                image: "JellyfinGlyph",
                iconSize: 22,
                title: server.name,
                subtitle: "Jellyfin · \(server.host) · Signed out"
            )
        }
        .tvListRowButton()
        .accessibilityHint("Sign in again or remove this server")
        // Attached per-row (not on the list) so iPad's popover rendering anchors to the tapped row.
        .confirmationDialog(
            "Signed out of \(server.name)",
            isPresented: $isPrompting,
            titleVisibility: .visible
        ) {
            Button("Sign In Again") { onSignIn(server) }
            Button("Remove Server", role: .destructive) { onRemove(server.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Deliberately doesn't name a cause. A row lands here two ways — the saved token
            // couldn't be READ (lost Keychain slot) or the server REJECTED it (revoked device,
            // server rebuild, the demo server's nightly reset) — and the user's move is the same
            // either way. Naming one would be wrong half the time.
            Text("Parallax is signed out of \(server.host). Sign in again to restore this server, or remove it.")
        }
    }
}

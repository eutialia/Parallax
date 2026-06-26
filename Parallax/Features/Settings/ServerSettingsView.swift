import SwiftUI
import ParallaxCore
import ParallaxJellyfin

/// Per-Jellyfin-server settings detail (handoff 3h) — pushed from a server row in `SettingsView`. The
/// VM-wiring shell: it maps the `Session` + `SettingsViewModel` into plain values + callbacks for
/// `ServerSettingsContentView`, and fetches the server version + reachability from the PUBLIC
/// `/System/Info/Public` endpoint (one call yields both: a successful fetch IS the "Connected" proof —
/// there's no live status stream, so this is a point-in-time check on appear). "Remove Server" is the
/// destructive sign-out (drops the session + token); the visible-libraries picker is wired in a later step.
struct ServerSettingsView: View {
    let session: Session
    let vm: SettingsViewModel

    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemove = false
    @State private var showingVisibleLibraries = false
    @State private var status: ConnectionStatus = .checking
    /// Fetched server version ("10.9.11"); nil renders a dash until the probe lands.
    @State private var version: String?
    /// "4 of 6" / "All" summary for the Visible Libraries row — refreshed when visibility changes.
    @State private var visibleSummary = "All"

    /// Point-in-time reachability of the server, derived from the public-info probe.
    enum ConnectionStatus { case checking, connected, offline }

    private var statusText: String {
        switch status {
        case .checking: return "Checking…"
        case .connected: return "Connected"
        case .offline: return "Offline"
        }
    }

    /// Green LED only when reachable; a muted tertiary dot while checking or offline.
    private var statusLed: Color {
        status == .connected ? Color.ok : Color.tertiaryLabel
    }

    var body: some View {
        ServerSettingsContentView(
            serverName: session.serverName,
            host: session.displayHost,
            userName: session.user.name,
            version: version,
            statusText: statusText,
            statusLed: statusLed,
            visibleLibrariesLabel: visibleSummary,
            signOutError: vm.signOutErrorMessage,
            onVisibleLibraries: { showingVisibleLibraries = true },
            onRemove: { isConfirmingRemove = true }
        )
        .navigationDestination(isPresented: $showingVisibleLibraries) {
            VisibleLibrariesView(session: session)
        }
        .task { await probeServer() }
        // Keyed on the library revision so a visibility change (which bumps it) refreshes the "N of M".
        .task(id: router.libraryReloadToken) { await loadLibrarySummary() }
        .confirmationDialog("Remove this server?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await vm.signOut(session)
                    // On success pop back — this server is gone. Always dismiss: if it was the last
                    // SOURCE the router routed to login and tore the panel down (a no-op dismiss);
                    // if an SMB source remains the router keeps the panel, so without this pop the user
                    // is stranded on a ghost page for a server that no longer exists. On failure stay
                    // so the shared vm's error message shows.
                    if vm.signOutErrorMessage == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(session.serverName) will be removed from your servers.")
        }
    }

    /// Fetch the server version + reachability from the unauthenticated public-info endpoint. A thrown
    /// request (offline / wrong host) flips the pill to "Offline"; the version stays nil → a dash.
    private func probeServer() async {
        let factory = DefaultJellyfinClientFactory(identityProvider: deps.deviceIdentityProvider)
        let client = await factory.make(serverURL: session.serverURL)
        do {
            version = try await client.serverVersion()
            status = .connected
        } catch {
            status = .offline
        }
    }

    /// Compute the "N of M" / "All" Visible Libraries summary from the server's collections + hidden set.
    /// A fetch failure leaves the previous label (the row stays useful even if the server is briefly down).
    private func loadLibrarySummary() async {
        let hidden = await deps.serverStore.hiddenCollectionIDs(for: session.id)
        guard let collections = try? await deps.jellyfinLibraryRepoFactory(session).collections() else { return }
        // A newer revision (e.g. rapid visibility toggles) cancels this task; don't let a stale fetch
        // that resolved after the cancel overwrite the fresher summary the newer task already wrote.
        guard !Task.isCancelled else { return }
        let total = collections.count
        let visible = collections.filter { !hidden.contains($0.id.rawValue) }.count
        visibleSummary = (total == 0 || visible == total) ? "All" : "\(visible) of \(total)"
    }
}

/// Pure, previewable presentation of the Jellyfin server detail: identity hero + Connection / Libraries
/// sections + the destructive Remove. Holds no view model — the parent maps VM state into plain values +
/// callbacks, so this renders in a `#Preview` with mock data.
struct ServerSettingsContentView: View {
    let serverName: String
    let host: String
    let userName: String
    /// Server version string ("10.9.11"); nil renders a dash until the probe lands.
    var version: String?
    var statusText: String = "Connected"
    var statusLed: Color = Color.ok
    /// Visible-libraries summary ("4 of 6"); computed in the visible-libraries step. Defaults to "All".
    var visibleLibrariesLabel: String = "All"
    var signOutError: String? = nil
    let onVisibleLibraries: () -> Void
    let onRemove: () -> Void

    private var versionLabel: String { version.map { "Jellyfin \($0)" } ?? "—" }

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            ServerIdentityHero(
                image: "JellyfinGlyph",
                name: serverName,
                meta: "Jellyfin · \(userName)",
                pills: [
                    StatusPillData(lead: .led(statusLed), text: statusText),
                    StatusPillData(lead: .symbol("info.circle"), text: versionLabel),
                ]
            )

            SettingsGroup(title: "Connection") {
                SettingsRowLabel(systemImage: "globe", title: "Address", value: host)
            }

            SettingsGroup(
                title: "Libraries",
                footer: "Choose which of this server’s libraries appear in Parallax."
            ) {
                SettingsListRow(
                    systemImage: "books.vertical",
                    title: "Visible Libraries",
                    value: visibleLibrariesLabel,
                    accessory: .chevron,
                    action: onVisibleLibraries
                )
            }

            SettingsGroup {
                SettingsListRow(systemImage: "trash", title: "Remove Server", role: .destructive, action: onRemove)
            }

            if let signOutError {
                Text(signOutError)
                    .font(.footnote)
                    .foregroundStyle(Color.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.headerInset)
            }
        }
        .navigationTitle(serverName)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if DEBUG
private struct JellyfinServerDetailPreview: View {
    var body: some View {
        NavigationStack {
            ServerSettingsContentView(
                serverName: "home-jellyfin",
                host: "jellyfin.example.lan",
                userName: "admin",
                version: "10.9.11",
                visibleLibrariesLabel: "4 of 6",
                onVisibleLibraries: {},
                onRemove: {}
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }
}

#if os(tvOS)
#Preview("Jellyfin server detail (tvOS)", traits: .fixedLayout(width: 1920, height: 1080)) { JellyfinServerDetailPreview() }
#else
#Preview("Jellyfin server detail (iOS)", traits: .fixedLayout(width: 540, height: 800)) { JellyfinServerDetailPreview() }
#endif
#endif

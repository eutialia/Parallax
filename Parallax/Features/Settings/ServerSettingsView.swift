import SwiftUI
import ParallaxCore
import ParallaxJellyfin
import ParallaxFeatures

/// Per-Jellyfin-server settings detail (handoff 3h) — pushed from a server row in `SettingsView`. The
/// VM-wiring shell: it maps the `Session` + `SettingsViewModel` into plain values + callbacks for
/// `ServerSettingsContentView`, and fetches the server version + reachability from the PUBLIC
/// `/System/Info/Public` endpoint (one call yields both: a successful fetch IS the "Connected" proof —
/// there's no live status stream, so this is a point-in-time check on appear). "Remove Server" is the
/// destructive sign-out (drops the session + token); the visible-libraries picker is wired in a later step.
struct ServerSettingsView: View {
    let session: Session
    let vm: SettingsViewModel
    let app: AppModel
    /// Pops this page. Not `\.dismiss`: a view that reads it and owns a `navigationDestination`
    /// re-renders on every change to it, and the pushed page's `tvHidesTabSidebar` changes it on
    /// every pass, so the push loops the render graph forever on tvOS.
    let onRemoved: () -> Void

    @State private var isConfirmingRemove = false
    @State private var showingVisibleLibraries = false
    @State private var model: ServerSettingsModel

    init(session: Session, vm: SettingsViewModel, app: AppModel, onRemoved: @escaping () -> Void) {
        self.session = session
        self.vm = vm
        self.app = app
        self.onRemoved = onRemoved
        _model = State(initialValue: ServerSettingsModel(session: session, app: app))
    }

    private var statusText: String {
        switch model.status {
        case .checking: return "Checking…"
        case .connected: return "Connected"
        case .offline: return "Offline"
        }
    }

    /// Green LED only when reachable; a muted tertiary dot while checking or offline.
    private var statusLed: Color {
        model.status == .connected ? Color.ok : Color.tertiaryLabel
    }

    var body: some View {
        ServerSettingsContentView(
            serverName: session.serverName,
            host: session.displayHost,
            userName: session.user.name,
            version: model.version,
            statusText: statusText,
            statusLed: statusLed,
            visibleLibrariesLabel: model.visibleSummary,
            signOutError: vm.signOutErrorMessage,
            onVisibleLibraries: { showingVisibleLibraries = true },
            onRemove: { isConfirmingRemove = true }
        )
        .navigationDestination(isPresented: $showingVisibleLibraries) {
            VisibleLibrariesView(session: session, app: app)
                .tvHidesTabSidebar()
        }
        .task {
            await model.probeServer()
        }
        .task {
            await model.run()
        }
        .confirmationDialog("Remove this server?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await vm.signOut(session)
                    // On success pop back — this server is gone. Always pop: if it was the last
                    // SOURCE the router routed to login and tore the panel down (a no-op pop);
                    // if an SMB source remains the router keeps the panel, so without this pop the user
                    // is stranded on a ghost page for a server that no longer exists. On failure stay
                    // so the shared vm's error message shows.
                    if vm.signOutErrorMessage == nil { onRemoved() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(session.serverName) will be removed from your servers.")
        }
    }
}

/// Pure, previewable presentation of the Jellyfin server detail: identity hero + Connection / Libraries
/// sections + the destructive Remove. Holds no view model — the parent maps VM state into plain values +
/// callbacks, so this renders in a `#Preview` with mock data.
struct ServerSettingsContentView: View {
    let serverName: String
    let host: String
    let userName: String
    /// Server version string ("12.2.0"); nil renders a dash until the probe lands.
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
                version: "12.2.0",
                visibleLibrariesLabel: "4 of 6",
                onVisibleLibraries: {},
                onRemove: {}
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenFloor()
    }
}

#if os(tvOS)
#Preview("Jellyfin server detail (tvOS)", traits: .fixedLayout(width: 1920, height: 1080)) { JellyfinServerDetailPreview() }
#else
#Preview("Jellyfin server detail (iOS)", traits: .fixedLayout(width: 540, height: 800)) { JellyfinServerDetailPreview() }
#endif
#endif

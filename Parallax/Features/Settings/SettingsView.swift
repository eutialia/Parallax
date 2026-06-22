import SwiftUI
import ParallaxJellyfin

/// The app's settings surface — the server list (switch / sign out) plus the add-server → sign-in
/// flow, so server management lives in one place. Shown two ways: a centered form sheet on iPad (from
/// the sidebar footer; `isModal` adds a Done button to dismiss it), and an inline tab on iPhone and
/// tvOS (the tab bar is the exit, so no Done button).
///
/// Layout + visual language come from `SettingsScaffold` (two-column brand-left on tvOS, brand-top on
/// iPad/iPhone) and `SettingsGroup`/`SettingsListRow` (flat grouped rows, the Settings.app idiom). The
/// view itself is the VM-wiring shell; `SettingsContentView` is the pure, previewable presentation.
///
/// The iPad sheet is presented from the stable `RootView`, above `RootTabView`'s `.id(activeServerID)`
/// remount, so switching or adding a server (which re-points the router) doesn't tear the panel down.
struct SettingsView: View {
    /// Presented modally as a sheet (iPad) vs. embedded as a tab (iPhone / tvOS). Modal gets a Done
    /// button to dismiss; the tab relies on the tab bar as its exit.
    var isModal: Bool = false

    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SettingsViewModel?
    @State private var path: [Route] = []
    /// The SMB server whose removal is being confirmed. SMB servers have no detail page, so pressing a
    /// row asks to confirm removal (both platforms — a confirmation guards the destructive action and
    /// keeps the row a single 10-foot focus target instead of a tiny trash glyph).
    @State private var smbServerPendingRemoval: PersistedServer?

    /// Pushed leaves of the settings stack. `.addServer` hosts `LoginView`, so the sign-in form is
    /// literally part of settings rather than a separate sheet.
    enum Route: Hashable {
        case server(Session)
        case addServer
        case addSMBServer
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                // tvOS omits the in-content title — the sidebar's "Settings" tab label already names
                // the screen, so a title at the top of the content just duplicates it.
                #if !os(tvOS)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if isModal {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .server(let session):
                        if let vm = viewModel {
                            ServerSettingsView(session: session, vm: vm)
                        }
                    case .addServer:
                        LoginView(onSignedIn: { handleAddedServer() })
                            .navigationTitle("Add Jellyfin Server")
                            #if !os(tvOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                    case .addSMBServer:
                        SMBLoginView(onAdded: { handleAddedSMBServer() })
                            .navigationTitle("Add SMB Server")
                            #if !os(tvOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                    }
                }
                .confirmationDialog(
                    "Remove this SMB server?",
                    isPresented: Binding(
                        get: { smbServerPendingRemoval != nil },
                        set: { if !$0 { smbServerPendingRemoval = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: smbServerPendingRemoval
                ) { server in
                    Button("Remove", role: .destructive) {
                        Task { await viewModel?.removeSMBServer(server.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { server in
                    if case .smb(let data) = server.kind {
                        Text("\(data.host) will be removed from your libraries.")
                    }
                }
        }
        // tvOS: pin the big app icon to the left, outside the stack, so it stays put across pushes
        // (server detail / add-server). No-op on iOS, where the brand rides each page.
        .tvSettingsBrandRail()
        // Centered floating card on iPad (regular width); a standard sheet on iPhone.
        #if !os(tvOS)
        .presentationSizing(.form)
        #endif
        .presentationBackground(Color.background)
        .task {
            if viewModel == nil {
                viewModel = SettingsViewModel(
                    sessionManager: deps.sessionManager,
                    serverStore: deps.serverStore,
                    router: router
                )
            }
            await viewModel?.refresh()
        }
    }

    @ViewBuilder
    private var root: some View {
        if let vm = viewModel {
            SettingsContentView(
                servers: vm.sessions.map {
                    SettingsServerRow(
                        id: $0.id,
                        name: $0.serverName,
                        host: $0.displayHost,
                        user: $0.user.name,
                        isActive: $0.id == vm.activeID
                    )
                },
                smbServers: vm.smbServers.compactMap { server in
                    guard case .smb(let data) = server.kind else { return nil }
                    let path = data.share + (data.root.isEmpty ? "" : "/\(data.root)")
                    return SettingsSMBRow(id: server.id, host: data.host, path: path, user: data.username)
                },
                signOutError: vm.signOutErrorMessage,
                onSelectServer: { id in
                    if let session = vm.sessions.first(where: { $0.id == id }) {
                        path.append(.server(session))
                    }
                },
                onRemoveSMB: { id in
                    smbServerPendingRemoval = vm.smbServers.first { $0.id == id }
                },
                onAddJellyfin: { path.append(.addServer) },
                onAddSMB: { path.append(.addSMBServer) },
                storage: { ThumbnailCacheCard() }
            )
        } else {
            ScrollView { ServerListLoadingSkeleton() }
                .scrollDisabled(true)
        }
    }

    /// After the pushed `LoginView` signs in: re-point the router at the now-active server, then pop
    /// back to the list so the new server is visible.
    private func handleAddedServer() {
        Task {
            await viewModel?.didAddServer()
            path = []
        }
    }

    /// After a successful SMB add: refresh the server list, bump the library revision so the navigation
    /// roots merge the new SMB source in immediately, and pop to root. Intentionally does NOT re-point
    /// the router — SMB servers are not active sessions; the active Jellyfin session is unchanged by
    /// this addition (the revision bump, not `activeServerID`, refreshes the sidebar).
    private func handleAddedSMBServer() {
        Task {
            await viewModel?.reloadAfterSMBChange()
            path = []
        }
    }
}

/// A Jellyfin server row's display data (top-level, so it doesn't depend on `SettingsContentView`'s
/// generic `Storage` parameter).
struct SettingsServerRow: Identifiable {
    let id: ServerID
    let name: String
    let host: String
    let user: String
    let isActive: Bool
}

/// An SMB server row's display data.
struct SettingsSMBRow: Identifiable {
    let id: ServerID
    let host: String
    let path: String
    let user: String
}

/// Pure, previewable presentation of the settings surface: the brand scaffold plus the Servers and
/// Storage groups. Holds no view model — the parent maps VM state into plain row data + callbacks, so
/// this renders in a `#Preview` with mock data (the real screen, minus the network).
struct SettingsContentView<Storage: View>: View {
    let servers: [SettingsServerRow]
    let smbServers: [SettingsSMBRow]
    var signOutError: String? = nil
    let onSelectServer: (ServerID) -> Void
    let onRemoveSMB: (ServerID) -> Void
    let onAddJellyfin: () -> Void
    let onAddSMB: () -> Void
    @ViewBuilder var storage: Storage

    var body: some View {
        SettingsScaffold(title: "Settings") {
            SettingsGroup(title: "Servers") {
                ForEach(servers) { server in
                    Button { onSelectServer(server.id) } label: {
                        SettingsRowLabel(
                            systemImage: "server.rack",
                            title: server.name,
                            subtitle: "\(server.host) · \(server.user)",
                            status: SettingsRowStatus(text: server.isActive ? "Active" : "Idle", isOn: server.isActive),
                            accessory: .chevron
                        )
                    }
                    .tvListRowButton()
                    .accessibilityHint("Opens server settings")
                }
                ForEach(smbServers) { server in
                    SettingsListRow(
                        systemImage: "externaldrive.connected.to.line.below.fill",
                        title: server.host,
                        subtitle: "\(server.path) · \(server.user)",
                        status: SettingsRowStatus(text: "Idle", isOn: false),
                        accessory: .trash,
                        action: { onRemoveSMB(server.id) }
                    )
                    // The trailing trash glyph is decorative; without this the destructive remove reads
                    // as a plain row. (Old smbServerCard carried an explicit "Remove {host}" label.)
                    .accessibilityHint("Removes this server")
                }
                addServerMenu
            }

            storage

            if let signOutError {
                Text(signOutError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s14)
            }
        }
    }

    private var addServerMenu: some View {
        Menu {
            Button { onAddJellyfin() } label: {
                Label("Jellyfin Server", image: "JellyfinGlyph")
            }
            Button { onAddSMB() } label: {
                Label("SMB / Network Share", systemImage: "externaldrive.connected.to.line.below.fill")
            }
        } label: {
            SettingsRowLabel(systemImage: "plus", title: "Add Server")
        }
        .tvListRowButton()
    }
}

#if DEBUG
#Preview("Settings · grouped", traits: .fixedLayout(width: 1920, height: 1080)) {
    SettingsContentView(
        servers: [
            .init(id: ServerID(rawValue: "1"), name: "Living Room", host: "jellyfin.local", user: "alice", isActive: true),
            .init(id: ServerID(rawValue: "2"), name: "Basement NAS", host: "192.168.1.10", user: "alice", isActive: false),
        ],
        smbServers: [
            .init(id: ServerID(rawValue: "3"), host: "192.168.1.10", path: "Media/Movies", user: "guest"),
        ],
        onSelectServer: { _ in },
        onRemoveSMB: { _ in },
        onAddJellyfin: {},
        onAddSMB: {},
        storage: {
            SettingsGroup(title: "Storage") {
                SettingsListRow(systemImage: "photo.stack", title: "Thumbnail Cache", value: "128 MB")
                SettingsListRow(systemImage: "trash", title: "Clear Cache", role: .destructive) {}
            }
        }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif

import SwiftUI
import ParallaxJellyfin

/// The app's settings surface — the server list plus the add-server → sign-in flow, so server
/// management lives in one place. Shown two ways: a centered form sheet on iPad (from the sidebar
/// footer; `isModal` adds a Done button), and an inline tab on iPhone and tvOS (the tab bar is the exit).
///
/// Layout + visual language come from `SettingsScaffold` (two-column brand-left on tvOS, brand-top on
/// iPad/iPhone) and `SettingsGroup`/`SettingsListRow` (the inset-grouped card idiom from the redesign
/// handoff). The view itself is the VM-wiring shell; `SettingsContentView` is the pure, previewable
/// presentation.
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
    /// iPhone only: the Add-Server task presents as its OWN page sheet (option #1 / Modality HIG —
    /// Settings is a tab there, not a sheet, so a fresh sheet with a Cancel is correct). iPad pushes the
    /// task within the existing form sheet (no stacked sheets); tvOS pushes full-screen.
    @State private var presentingAddServer = false

    /// Pushed leaves of the settings stack. A server row drills into its detail; `Add Server` opens the
    /// choose-type step, which pushes the matching sign-in form — all inside this stack, so the whole
    /// add task is literally part of Settings.
    enum Route: Hashable {
        case server(Session)
        case smbServer(PersistedServer)
        case addServerChoose
        case addJellyfin
        case addSMB
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                // tvOS omits the in-content title — the sidebar's "Settings" tab label already names the
                // screen, so a title at the top of the content just duplicates it.
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
                    destination(for: route)
                }
                #if !os(tvOS)
                .sheet(isPresented: $presentingAddServer) {
                    if let viewModel {
                        AddServerFlow(
                            onAddedJellyfin: { Task { await viewModel.didAddServer() } },
                            onAddedSMB: { Task { await viewModel.reloadAfterSMBChange() } }
                        )
                    }
                }
                #endif
        }
        // tvOS: pin the big app icon to the left, outside the stack, so it stays put across pushes.
        // No-op on iOS, where the brand rides each page.
        .tvSettingsBrandRail()
        // Presentation modifiers only take effect when Settings is shown as a SHEET (iPad). On
        // iPhone/tvOS it's an embedded tab with no presentation to size or back, so both are inert there.
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
    private func destination(for route: Route) -> some View {
        switch route {
        case .server(let session):
            if let vm = viewModel {
                ServerSettingsView(session: session, vm: vm)
            }
        case .smbServer(let server):
            SMBServerSettingsView(server: server)
        case .addServerChoose:
            AddServerChooseView(
                onChooseJellyfin: { path.append(.addJellyfin) },
                onChooseSMB: { path.append(.addSMB) }
            )
        case .addJellyfin:
            LoginView(onSignedIn: { handleAddedServer() })
                .navigationTitle("Add Jellyfin Server")
                #if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        case .addSMB:
            SMBLoginView(onAdded: { handleAddedSMBServer() })
                .navigationTitle("Add SMB Server")
                #if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }

    @ViewBuilder
    private var root: some View {
        if let vm = viewModel {
            SettingsContentView(
                jellyfinServers: vm.sessions.map {
                    SettingsJellyfinRow(id: $0.id, name: $0.serverName, host: $0.displayHost)
                },
                smbServers: Self.smbServerRows(vm.smbServers),
                signOutError: vm.signOutErrorMessage,
                onSelectJellyfin: { id in
                    if let session = vm.sessions.first(where: { $0.id == id }) {
                        path.append(.server(session))
                    }
                },
                onSelectSMBServer: { server in path.append(.smbServer(server)) },
                onAddServer: {
                    // iPad (Settings IS a form sheet) and tvOS push the task in place; iPhone presents it
                    // as its own page sheet so Cancel aborts the whole flow in one tap (option #1).
                    #if os(tvOS)
                    path.append(.addServerChoose)
                    #else
                    if isModal { path.append(.addServerChoose) } else { presentingAddServer = true }
                    #endif
                },
                storage: { ThumbnailCacheCard() }
            )
        } else {
            ScrollView { ServerListLoadingSkeleton() }
                .scrollDisabled(true)
        }
    }

    /// Maps each `.smb` `PersistedServer` to a display row — one row per server, one server per host.
    static func smbServerRows(_ servers: [PersistedServer]) -> [SettingsSMBServerRow] {
        servers.compactMap { server in
            guard case .smb(let data) = server.kind else { return nil }
            return SettingsSMBServerRow(server: server, host: data.host, subtitle: data.shareCountSubtitle)
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

    /// After a successful SMB add: refresh the list, bump the library revision so the navigation roots
    /// merge the new SMB source in immediately, and pop to root. Does NOT re-point the router — SMB
    /// servers are not active sessions.
    private func handleAddedSMBServer() {
        Task {
            await viewModel?.reloadAfterSMBChange()
            path = []
        }
    }
}

#if !os(tvOS)
/// The iPhone Add-Server task as its OWN page sheet (handoff option #1): a self-contained
/// `NavigationStack` from the choose-type step, with a Cancel that aborts the whole task. Each sign-in
/// step pushes INSIDE this sheet with a back chevron. iPad doesn't use this — there Settings is already a
/// form sheet, so the task pushes within it (no stacked sheets, per the Modality HIG).
private struct AddServerFlow: View {
    var onAddedJellyfin: () -> Void
    var onAddedSMB: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsView.Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            AddServerChooseView(
                onChooseJellyfin: { path.append(.addJellyfin) },
                onChooseSMB: { path.append(.addSMB) }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsView.Route.self) { route in
                switch route {
                case .addJellyfin:
                    LoginView(onSignedIn: { onAddedJellyfin(); dismiss() })
                        .navigationTitle("Jellyfin")
                        .navigationBarTitleDisplayMode(.inline)
                case .addSMB:
                    SMBLoginView(onAdded: { onAddedSMB(); dismiss() })
                        .navigationTitle("Network Share")
                        .navigationBarTitleDisplayMode(.inline)
                default:
                    EmptyView()
                }
            }
        }
        .presentationBackground(Color.background)
    }
}
#endif

/// A Jellyfin server row's display data (top-level, so it doesn't depend on `SettingsContentView`'s
/// generic `Storage` parameter).
struct SettingsJellyfinRow: Identifiable {
    let id: ServerID
    let name: String
    let host: String
}

/// An SMB server's row data — one row per persisted server (one server per host).
struct SettingsSMBServerRow: Identifiable {
    let server: PersistedServer
    let host: String
    let subtitle: String
    var id: ServerID { server.id }
    /// Row meta line: "SMB · N shares".
    var meta: String { "SMB · \(subtitle)" }
}

/// Pure, previewable presentation of the settings root: the Servers, Playback, and Storage sections,
/// then the build line. Holds no view model — the parent maps VM state into plain row data + callbacks,
/// so this renders in a `#Preview` with mock data (the real screen, minus the network).
struct SettingsContentView<Storage: View>: View {
    let jellyfinServers: [SettingsJellyfinRow]
    let smbServers: [SettingsSMBServerRow]
    var signOutError: String? = nil
    let onSelectJellyfin: (ServerID) -> Void
    let onSelectSMBServer: (PersistedServer) -> Void
    let onAddServer: () -> Void
    @ViewBuilder var storage: Storage

    var body: some View {
        // The redesign root is a plain inset-grouped list under the "Settings" nav title — no brand
        // lockup (that's the logged-out Connect flow's identity, not the signed-in settings root).
        SettingsScaffold(showsBrand: false) {
            serversSection
            playbackSection
            storage
            // iOS/iPadOS show the build line at the end of the list; tvOS relocates it to the top-right
            // tag in the chrome (handoff `.tv-build`) — see `RootBuildTag` below.
            #if !os(tvOS)
            SettingsBuildLine()
            #endif
            if let signOutError {
                Text(signOutError)
                    .font(.footnote)
                    .foregroundStyle(Color.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.headerInset)
            }
        }
        .modifier(RootBuildTag())
    }

    private var serversSection: some View {
        SettingsGroup(title: "Servers") {
            ForEach(jellyfinServers) { server in
                Button { onSelectJellyfin(server.id) } label: {
                    SettingsRowLabel(
                        image: "JellyfinGlyph",
                        // 18, not the sibling rows' 22: `JellyfinGlyph` fills its frame edge-to-edge,
                        // while an SF Symbol at `size:` only inks ~75% of its em box — so 18 here lands
                        // the mark at the same visual height as `externaldrive.badge.wifi`@22 next to it.
                        iconSize: 18,
                        title: server.name,
                        subtitle: "Jellyfin · \(server.host)",
                        accessory: .chevron
                    )
                }
                .tvListRowButton()
                .accessibilityHint("Opens server settings")
            }
            ForEach(smbServers) { row in
                Button { onSelectSMBServer(row.server) } label: {
                    SettingsRowLabel(
                        systemImage: "externaldrive.badge.wifi",
                        iconSize: 22,
                        title: row.host,
                        subtitle: row.meta,
                        accessory: .chevron
                    )
                }
                .tvListRowButton()
                .accessibilityHint("Opens share settings")
            }
            Button { onAddServer() } label: {
                SettingsRowLabel(systemImage: "plus", title: "Add Server", isAccent: true)
            }
            .tvListRowButton()
        }
    }

    private var playbackSection: some View {
        SettingsGroup(title: "Playback", footer: "Playback preferences are coming in a future update.") {
            SettingsListRow(systemImage: "film", title: "Video", accessory: .soon)
            SettingsListRow(systemImage: "waveform", title: "Audio", accessory: .soon)
            SettingsListRow(systemImage: "captions.bubble", title: "Subtitles", accessory: .soon)
        }
    }
}

/// The version line under the settings root (handoff `.verfoot` / `.buildline` / `.tv-build`): present
/// on every platform per the parity rules. Reads the app's short version + build from the bundle.
struct SettingsBuildLine: View {
    var body: some View {
        Text(Self.versionText)
            .font(.rowSubtitle)
            .foregroundStyle(Color.tertiaryLabel)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Space.s8)
            .accessibilityLabel("App version \(Self.versionText)")
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Parallax \(short) (\(build))"
    }
}

/// Routes the settings root's version text to the tvOS top-right chrome tag (`SettingsBuildTagKey`):
/// only the root sets it, so it shows on the root and clears on pushed sub-screens. No-op on iOS, where
/// the build line renders inline at the end of the list instead.
private struct RootBuildTag: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.preference(key: SettingsBuildTagKey.self, value: SettingsBuildLine.versionText)
        #else
        content
        #endif
    }
}

#if DEBUG
private struct SettingsRootPreview: View {
    var body: some View {
        SettingsContentView(
            jellyfinServers: [
                .init(id: ServerID(rawValue: "1"), name: "home-jellyfin", host: "jellyfin.example.lan"),
            ],
            smbServers: [
                .init(server: PersistedServer(id: ServerID(rawValue: "s1"), kind: .smb(SMBServerData(host: "mynas.local", username: "", domain: "", shares: ["Media"]))), host: "mynas.local", subtitle: "1 share"),
                .init(server: PersistedServer(id: ServerID(rawValue: "s2"), kind: .smb(SMBServerData(host: "nas2.local", username: "", domain: "", shares: ["Media", "TV"]))), host: "nas2.local", subtitle: "2 shares"),
            ],
            onSelectJellyfin: { _ in },
            onSelectSMBServer: { _ in },
            onAddServer: {},
            storage: {
                SettingsGroup(
                    title: "Storage",
                    footer: "Cached artwork and thumbnails. Clearing won’t remove anything from your sources."
                ) {
                    SettingsListRow(systemImage: "photo.on.rectangle", title: "Thumbnail Cache", value: "7.7 MB")
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }
}

#if os(tvOS)
#Preview("Settings · root (tvOS)", traits: .fixedLayout(width: 1920, height: 1080)) { SettingsRootPreview() }
#else
#Preview("Settings · root (iOS)", traits: .fixedLayout(width: 540, height: 980)) { SettingsRootPreview() }
#endif
#endif

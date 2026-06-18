import SwiftUI
import ParallaxJellyfin

/// The app's settings surface — the server list (switch / sign out) plus the add-server →
/// sign-in flow, so server management lives in one place. Shown two ways: a centered form sheet
/// on iPad (from the sidebar footer; `isModal` adds a Done button to dismiss it), and an inline
/// tab on iPhone and tvOS (the tab bar is the exit, so no Done button).
///
/// The iPad sheet is presented from the stable `RootView`, above `RootTabView`'s
/// `.id(activeServerID)` remount, so switching or adding a server (which re-points the router)
/// doesn't tear the panel down.
struct SettingsView: View {
    /// Presented modally as a sheet (iPad) vs. embedded as a tab (iPhone / tvOS). Modal gets a
    /// Done button to dismiss; the tab relies on the tab bar as its exit.
    var isModal: Bool = false

    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SettingsViewModel?
    @State private var path: [Route] = []
    /// tvOS: the SMB card whose removal is being confirmed. A lone trash glyph is a poor 10-foot
    /// focus target, so the whole card is the button and this drives the confirmation dialog. iOS
    /// removes inline from the card's trash button and never sets this.
    #if os(tvOS)
    @State private var smbServerPendingRemoval: PersistedServer?
    #endif

    /// Pushed leaves of the settings stack. `.addServer` hosts `LoginView`, so the sign-in
    /// form is literally part of settings rather than a separate sheet.
    enum Route: Hashable {
        case server(Session)
        case addServer
        case addSMBServer
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                // tvOS omits the in-content title — the sidebar's "Settings" tab label already
                // names the screen, so a title at the top of the content just duplicates it.
                #if !os(tvOS)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    // Only the modal sheet (iPad) needs a dismiss affordance; the tab (iPhone /
                    // tvOS) is left via the tab bar.
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
                #if os(tvOS)
                // tvOS removal confirmation for the whole-card SMB remove button (see `smbServerCard`).
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
                #endif
        }
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

    // MARK: - Root

    @ViewBuilder
    private var root: some View {
        if let vm = viewModel {
            ScrollView {
                VStack(spacing: Space.s22) {
                    // App identity at the top of Settings — the app icon + "Parallax" moved here from
                    // the add-server form so both add-server pages (Jellyfin / SMB) are mark-less and
                    // identical; this is the one place the brand mark lives once you're signed in.
                    BrandMark(glyph: .brandIcon, title: "Parallax")
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, Space.s8)
                    serversSection(vm)
                    storageSection
                    if let message = vm.signOutErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.s14)
                    }
                }
                .padding(Space.s18)
                .frame(maxWidth: AppLayout.settingsContentWidth)
                .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView { ServerListLoadingSkeleton() }
                .scrollDisabled(true)
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text("Storage")
                .font(.sectionHeader)
                .textCase(.uppercase)
                .foregroundStyle(Color.secondaryLabel)
                .padding(.horizontal, Space.s14)
            ThumbnailCacheCard()
        }
    }

    // MARK: - Servers

    @ViewBuilder
    private func serversSection(_ vm: SettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text("Servers")
                .font(.sectionHeader)
                .textCase(.uppercase)
                .foregroundStyle(Color.secondaryLabel)
                .padding(.horizontal, Space.s14)
            VStack(spacing: Space.s12) {
                ForEach(vm.sessions) { serverCard($0, vm: vm) }
                ForEach(vm.smbServers) { smbServerCard($0, vm: vm) }
                addServerButton
            }
        }
    }

    /// Server / SMB card icon tile — larger at 10 feet (per the audit: 46 iPad / 52 tvOS).
    private var serverIconTileSize: CGFloat {
        #if os(tvOS)
        52
        #else
        46
        #endif
    }

    private func serverCard(_ session: Session, vm: SettingsViewModel) -> some View {
        let host = session.displayHost
        let isActive = session.id == vm.activeID
        let a11yBase = "\(session.serverName), \(host), \(session.user.name)"
        // The whole card pushes the server's settings page (make-active / sign-out live
        // there). The active server keeps its green status pill for a quick glance.
        return NavigationLink(value: Route.server(session)) {
            HStack(spacing: Space.s14) {
                IconTile(systemImage: "server.rack", size: serverIconTileSize, cornerRadius: 10, glyphSize: 18, glyphWeight: .regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.serverName).font(.rowTitle).foregroundStyle(Color.label)
                    Text(host)
                        .font(.rowSubtitle).foregroundStyle(Color.secondaryLabel).lineLimit(1)
                    Text(session.user.name).font(.rowSubtitle).foregroundStyle(Color.tertiaryLabel)
                }
                Spacer(minLength: 0)
                // LED + state on every server row: Active (--ok green) vs Idle (dim), so a glance
                // reads which session is live — per the audit's Active/Idle status.
                HStack(spacing: 5) {
                    Circle().fill(isActive ? Color.ok : Color.tertiaryLabel).frame(width: 8, height: 8)
                    Text(isActive ? "Active" : "Idle").font(.rowSubtitle).foregroundStyle(Color.secondaryLabel)
                }
                Image(systemName: "chevron.right")
                    .scaledFont(13, relativeTo: .footnote, weight: .semibold)
                    .foregroundStyle(Color.tertiaryLabel)
            }
            // Chrome lives INSIDE the link's label so the tvOS focus lift scales the glass
            // card whole — applied outside, the content lifted while the panel stayed put.
            .padding(Space.s14)
            .surfacePanel(cornerRadius: Radius.card)
            .contentShape(.rect)
        }
        // A glass-panel row is chrome, not poster art — use the gentle chrome lift, not the
        // poster `.borderless` focus.
        .tvChipButton()
        // One self-describing element with a navigation hint (the chevron is decorative
        // and the "Active" pill would otherwise read as a loose trailing word).
        .accessibilityLabel(isActive ? "\(a11yBase), active server" : a11yBase)
        .accessibilityHint("Opens server settings")
    }

    private var addServerButton: some View {
        Menu {
            Button {
                path.append(Route.addServer)
            } label: {
                Label("Jellyfin Server", systemImage: "hexagon.fill")
            }
            // SMB is offered on every platform now that `FocusRootView` renders an SMB-only home —
            // signing out the last Jellyfin server with an SMB source remaining lands there, not on
            // a stranded launch spinner.
            Button {
                path.append(Route.addSMBServer)
            } label: {
                Label("SMB / Network Share", systemImage: "externaldrive.connected.to.line.below.fill")
            }
        } label: {
            Label("Add Server", systemImage: "plus")
                .formActionLabel(.glass)
        }
        .formActionButton(.glass)
        .padding(.top, Space.s8)
    }

    // `@ViewBuilder` + `if case` (not `guard ... return AnyView`): SwiftUI can't diff through
    // AnyView, so the erased card fully re-rendered on every settings-list update.
    @ViewBuilder
    private func smbServerCard(_ server: PersistedServer, vm: SettingsViewModel) -> some View {
        if case .smb(let data) = server.kind {
            let content = HStack(spacing: Space.s14) {
                IconTile(systemImage: "externaldrive.connected.to.line.below.fill", size: serverIconTileSize, cornerRadius: 10, glyphSize: 18, glyphWeight: .regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.host).font(.rowTitle).foregroundStyle(Color.label)
                    Text(data.share + (data.root.isEmpty ? "" : "/\(data.root)"))
                        .font(.rowSubtitle).foregroundStyle(Color.secondaryLabel).lineLimit(1)
                    Text(data.username).font(.rowSubtitle).foregroundStyle(Color.tertiaryLabel)
                }
                Spacer(minLength: 0)
                // SMB shares aren't live sessions, so they read as Idle — the same status vocabulary
                // as the Jellyfin rows (per the audit), so every server row stays visually consistent.
                HStack(spacing: 5) {
                    Circle().fill(Color.tertiaryLabel).frame(width: 8, height: 8)
                    Text("Idle").font(.rowSubtitle).foregroundStyle(Color.secondaryLabel)
                }
                // iOS removes inline from a trailing trash button; tvOS makes the whole card the
                // remove action (below) — a lone trash glyph is a poor 10-foot focus target.
                #if !os(tvOS)
                Button(role: .destructive) {
                    Task { await vm.removeSMBServer(server.id) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.leading, Space.s8)
                .accessibilityLabel("Remove \(data.host)")
                #endif
            }
            .padding(Space.s14)
            .surfacePanel(cornerRadius: Radius.card)
            .contentShape(.rect)

            #if os(tvOS)
            // The whole card is the focus target (gentle glass-chip lift, like the Jellyfin server
            // card). SMB servers have no detail page, so pressing asks to confirm removal.
            Button { smbServerPendingRemoval = server } label: { content }
                .tvChipButton()
                .accessibilityLabel("Remove \(data.host)")
            #else
            content
            #endif
        }
    }

    /// After the pushed `LoginView` signs in: re-point the router at the now-active server,
    /// then pop back to the list so the new server is visible.
    private func handleAddedServer() {
        Task {
            await viewModel?.didAddServer()
            path = []
        }
    }

    /// After a successful SMB add: refresh the server list, bump the library revision so the
    /// navigation roots merge the new SMB source in immediately, and pop to root. Intentionally
    /// does NOT re-point the router — SMB servers are not active sessions; the active Jellyfin
    /// session is unchanged by this addition (the revision bump, not `activeServerID`, refreshes
    /// the sidebar).
    private func handleAddedSMBServer() {
        Task {
            await viewModel?.reloadAfterSMBChange()
            path = []
        }
    }
}

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
                    serversSection(vm)
                    if let message = vm.signOutErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.s14)
                    }
                }
                .padding(Space.s18)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView { ServerListLoadingSkeleton() }
                .scrollDisabled(true)
        }
    }

    // MARK: - Servers

    @ViewBuilder
    private func serversSection(_ vm: SettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text("Servers")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Color.secondaryLabel)
                .padding(.horizontal, Space.s14)
            VStack(spacing: Space.s12) {
                ForEach(vm.sessions) { serverCard($0, vm: vm) }
                ForEach(vm.smbServers) { smbServerCard($0, vm: vm) }
                addServerButton
            }
        }
        #if DEBUG
        VStack(alignment: .leading, spacing: Space.s8) {
            Text("Debug")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Color.secondaryLabel)
                .padding(.horizontal, Space.s14)
            smbSpikeLink
            smbListSpikeLink
        }
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
                IconTile(systemImage: "server.rack", size: 44, cornerRadius: 10, glyphSize: 18, glyphWeight: .regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.serverName).font(.headline).foregroundStyle(Color.label)
                    Text(host)
                        .font(.caption).foregroundStyle(Color.secondaryLabel).lineLimit(1)
                    Text(session.user.name).font(.caption).foregroundStyle(Color.tertiaryLabel)
                }
                Spacer(minLength: 0)
                if isActive {
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Active").font(.caption).foregroundStyle(Color.secondaryLabel)
                    }
                }
                Image(systemName: "chevron.right")
                    .scaledFont(13, relativeTo: .footnote, weight: .semibold)
                    .foregroundStyle(Color.tertiaryLabel)
            }
            // Chrome lives INSIDE the link's label so the tvOS focus lift scales the glass
            // card whole — applied outside, the content lifted while the panel stayed put.
            .padding(Space.s14)
            .glassPanel(cornerRadius: Radius.card)
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

    private func smbServerCard(_ server: PersistedServer, vm: SettingsViewModel) -> some View {
        guard case .smb(let data) = server.kind else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: Space.s14) {
                IconTile(systemImage: "externaldrive.connected.to.line.below.fill", size: 44, cornerRadius: 10, glyphSize: 18, glyphWeight: .regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.host).font(.headline).foregroundStyle(Color.label)
                    Text(data.share + (data.root.isEmpty ? "" : "/\(data.root)"))
                        .font(.caption).foregroundStyle(Color.secondaryLabel).lineLimit(1)
                    Text(data.username).font(.caption).foregroundStyle(Color.tertiaryLabel)
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    Task { await vm.removeSMBServer(server.id) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(data.host)")
            }
            .padding(Space.s14)
            .glassPanel(cornerRadius: Radius.card)
            .contentShape(.rect)
        )
    }

    // MARK: - DEBUG-only spike harness (deleted in Phase 2 Task 12)

    #if DEBUG
    private var smbSpikeLink: some View {
        NavigationLink(destination: SMBPlaybackSpikeView()) {
            Label("SMB Playback Spike", systemImage: "network")
                .formActionLabel(.glass)
        }
        .formActionButton(.glass)
    }

    private var smbListSpikeLink: some View {
        NavigationLink(destination: SMBListSpikeView()) {
            Label("SMB List Spike", systemImage: "folder.badge.questionmark")
                .formActionLabel(.glass)
        }
        .formActionButton(.glass)
    }
    #endif

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

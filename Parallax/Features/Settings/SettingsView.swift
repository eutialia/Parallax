import SwiftUI
import ParallaxJellyfin

/// The app's floating settings panel — a centered form sheet presented from the sidebar
/// account footer (regular width) or the nav-bar account button (compact). It owns the
/// server list (switch / sign out) and the add-server → sign-in flow, so all account
/// management lives in one floating place instead of a full-page tab (the Apple TV pattern).
///
/// Presented from the stable `RootView`, above `RootTabView`'s `.id(activeServerID)` remount,
/// so switching or adding a server (which re-points the router) doesn't tear the panel down.
struct SettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SettingsViewModel?
    @State private var path: [Route] = []
    @ScaledMetric(relativeTo: .headline) private var addServerHeight: CGFloat = 50

    /// Pushed leaves of the settings stack. `.addServer` hosts `LoginView`, so the sign-in
    /// form is literally part of settings rather than a separate sheet.
    enum Route: Hashable {
        case server(Session)
        case addServer
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
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
                            .navigationTitle("Add Server")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
        }
        // Centered floating card on iPad (regular width); a standard sheet on iPhone.
        .presentationSizing(.form)
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
                    if let active = vm.sessions.first(where: { $0.id == vm.activeID }) {
                        accountHeader(active)
                    }
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
            .background(Color.background)
        } else {
            ScrollView { ServerListLoadingSkeleton() }
                .scrollDisabled(true)
                .background(Color.background)
        }
    }

    /// Active-account identity at the top of the panel (avatar · name · host).
    private func accountHeader(_ session: Session) -> some View {
        HStack(spacing: Space.s14) {
            AccountAvatar(name: session.user.name, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.user.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(session.displayHost)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s18)
        .glassBar(cornerRadius: Radius.card)
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
                addServerButton
            }
        }
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
                    Text(session.user.name).font(.caption2).foregroundStyle(Color.tertiaryLabel)
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // One self-describing element with a navigation hint (the chevron is decorative
        // and the "Active" pill would otherwise read as a loose trailing word).
        .accessibilityLabel(isActive ? "\(a11yBase), active server" : a11yBase)
        .accessibilityHint("Opens server settings")
        .padding(Space.s14)
        .glassPanel(cornerRadius: Radius.card)
    }

    private var addServerButton: some View {
        NavigationLink(value: Route.addServer) {
            Label("Add Server", systemImage: "plus")
                .font(.headline).foregroundStyle(Color.label)
                .frame(maxWidth: .infinity).frame(height: addServerHeight)
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: Radius.field)
        .padding(.top, Space.s8)
    }

    /// After the pushed `LoginView` signs in: re-point the router at the now-active server,
    /// then pop back to the list so the new server is visible.
    private func handleAddedServer() {
        Task {
            await viewModel?.didAddServer()
            path = []
        }
    }
}

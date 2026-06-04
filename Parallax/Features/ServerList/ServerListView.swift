import SwiftUI
import ParallaxJellyfin

struct ServerListView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: ServerListViewModel?
    /// "Add Another Server" button height scales with Dynamic Type (relative to its
    /// `.headline` label).
    @ScaledMetric(relativeTo: .headline) private var addServerHeight: CGFloat = 50

    var body: some View {
        content
            .navigationTitle("Servers")
            // Registered on the always-present container (not gated on the loaded vm)
            // so a footer-initiated push from RootTabView resolves even before the
            // list's view model finishes loading.
            .navigationDestination(for: Session.self) { session in
                if let vm = viewModel {
                    ServerSettingsView(session: session, vm: vm)
                } else {
                    ProgressView()
                }
            }
            .background(Color.background)
            .task {
                // Build + refresh together inside the guard so the .task re-firing
                // when `content`'s identity flips (ProgressView → list once the VM
                // loads) doesn't trigger a second redundant refresh on first open.
                if viewModel == nil {
                    viewModel = ServerListViewModel(
                        sessionManager: deps.sessionManager,
                        serverStore: deps.serverStore,
                        router: router
                    )
                    await viewModel?.refresh()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            // @Bindable lets us pass $vm.presentingAddServer straight to the
            // sheet modifier — no hand-rolled Binding(get:set:) that defers
            // state propagation through an async Task.
            @Bindable var vm = vm
            list(vm: vm)
                .sheet(isPresented: $vm.presentingAddServer, onDismiss: {
                    // dismissAddServer (not refresh) re-points the router at the
                    // now-active server so the tabs remount onto a newly-added one.
                    Task { await vm.dismissAddServer() }
                }) {
                    LoginView()
                        // Match the sheet surface to the app background so iOS doesn't
                        // paint its default system platter as a margin around the card.
                        .presentationBackground(Color.background)
                }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func list(vm: ServerListViewModel) -> some View {
        ScrollView {
            VStack(spacing: Space.s12) {
                if let message = vm.signOutErrorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if vm.sessions.isEmpty {
                    ContentUnavailableView("No servers", systemImage: "server.rack",
                        description: Text("Add a Jellyfin server to get started."))
                        .padding(.top, Space.s60)
                } else {
                    ForEach(vm.sessions) { session in
                        serverCard(session, vm: vm)
                    }
                }
                Button {
                    vm.presentAddServer()
                } label: {
                    Label("Add Another Server", systemImage: "plus")
                        .font(.headline).foregroundStyle(Color.label)
                        .frame(maxWidth: .infinity).frame(height: addServerHeight)
                }
                .glassPanel(cornerRadius: Radius.field)
                .padding(.top, Space.s8)
            }
            .padding(Space.s18)
        }
    }

    @ViewBuilder
    private func serverCard(_ session: Session, vm: ServerListViewModel) -> some View {
        let host = session.serverURL.host() ?? session.serverURL.absoluteString
        let isActive = session.id == vm.activeID
        let a11yBase = "\(session.serverName), \(host), \(session.user.name)"
        // The whole card pushes the server's settings page (make-active / sign-out now
        // live there). The active server keeps its green status pill for a quick glance.
        NavigationLink(value: session) {
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
}

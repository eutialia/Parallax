import SwiftUI
import ParallaxJellyfin

struct ServerListView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: ServerListViewModel?

    var body: some View {
        content
            .navigationTitle("Servers")
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
                        .padding(.top, 60)
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
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .glassPanel(cornerRadius: Radius.field)
                .padding(.top, Space.s8)
            }
            .padding(Space.s18)
        }
    }

    @ViewBuilder
    private func serverCard(_ session: Session, vm: ServerListViewModel) -> some View {
        HStack(spacing: Space.s14) {
            // The card body (tap to make active) is its own Button so it doesn't
            // compete with the trailing Menu's gesture — a card-wide onTapGesture
            // would swallow the ellipsis tap and switch servers instead.
            Button {
                Task { await vm.setActive(session.id) }
            } label: {
                HStack(spacing: Space.s14) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.fill)
                        .frame(width: 44, height: 44)
                        .overlay { Image(systemName: "server.rack").foregroundStyle(Color.label) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.serverName).font(.headline).foregroundStyle(Color.label)
                        Text(session.serverURL.host ?? session.serverURL.absoluteString)
                            .font(.caption).foregroundStyle(Color.secondaryLabel).lineLimit(1)
                        Text(session.user.name).font(.caption2).foregroundStyle(Color.tertiaryLabel)
                    }
                    Spacer(minLength: 0)
                    if session.id == vm.activeID {
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Active").font(.caption).foregroundStyle(Color.secondaryLabel)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                if session.id != vm.activeID {
                    Button("Make Active") { Task { await vm.setActive(session.id) } }
                }
                Button("Sign Out", role: .destructive) { Task { await vm.signOut(session) } }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(width: 32, height: 32).contentShape(.rect)
            }
        }
        .padding(Space.s14)
        .glassPanel(cornerRadius: Radius.card)
    }
}

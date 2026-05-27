import SwiftUI
import ParallaxJellyfin

struct ServerListView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: ServerListViewModel?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Servers")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel?.presentAddServer()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(viewModel == nil)
                    }
                }
        }
        .task {
            if viewModel == nil {
                viewModel = ServerListViewModel(
                    sessionManager: deps.sessionManager,
                    serverStore: deps.serverStore,
                    router: router
                )
            }
            await viewModel?.refresh()
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
                    Task { await vm.refresh() }
                }) {
                    LoginView()
                }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func list(vm: ServerListViewModel) -> some View {
        if vm.sessions.isEmpty {
            ContentUnavailableView(
                "No servers",
                systemImage: "server.rack",
                description: Text("Add a Jellyfin server to get started.")
            )
        } else {
            List {
                if let message = vm.signOutErrorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                ForEach(vm.sessions) { session in
                    row(for: session, vm: vm)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for session: Session, vm: ServerListViewModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.serverName).font(.headline)
                Text("\(session.user.name) — \(session.serverURL.host ?? session.serverURL.absoluteString)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.id == vm.activeID {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            Task { await vm.setActive(session.id) }
        }
        .swipeActions {
            Button(role: .destructive) {
                Task { await vm.signOut(session) }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}

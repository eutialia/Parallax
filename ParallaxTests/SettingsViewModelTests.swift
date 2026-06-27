import Foundation
import Testing
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// Locks in the contract the SMB server-settings screen relies on when it hands removal to the shared
/// view model: removing a server must refresh the *published* `smbServers` list immediately (and fire
/// the sidebar reload), not just mutate the store. The bug this guards: the detail view used to remove
/// the server with its own inline copy of this logic that skipped the refresh, so the removed server
/// lingered as a ghost row in the settings server list until Settings was closed and reopened.
@Suite("Settings view model · SMB server removal")
@MainActor
struct SettingsViewModelTests {
    /// `SettingsViewModel` requires a `SessionManager`, but the SMB-removal path never reaches the
    /// network. This factory just satisfies the initializer and traps if anything ever calls into it.
    private struct UnusedClientFactory: JellyfinClientFactory {
        func make(serverURL: URL) async -> JellyfinAuthClient {
            fatalError("JellyfinClientFactory.make must not be reached in SMB-removal tests")
        }
    }

    private func makeStore() -> ServerStore {
        let suiteName = "SettingsViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ServerStore(settings: SettingsStore(defaults: defaults), keychain: FakeKeychain())
    }

    private func makeViewModel(store: ServerStore, router: AppRouter) -> SettingsViewModel {
        SettingsViewModel(
            sessionManager: SessionManager(serverStore: store, factory: UnusedClientFactory()),
            serverStore: store,
            router: router
        )
    }

    private func smbData(host: String) -> SMBServerData {
        SMBServerData(host: host, username: "alice", domain: "WORKGROUP", shares: ["Media"])
    }

    @Test("removeSMBServer drops the server from the published list right away — no panel reopen")
    func removeRefreshesPublishedList() async throws {
        let store = makeStore()
        let router = AppRouter()
        let keep = try await store.addSMBServer(smbData(host: "keep.local"), password: "pw")
        let drop = try await store.addSMBServer(smbData(host: "drop.local"), password: "pw")

        let vm = makeViewModel(store: store, router: router)
        await vm.refresh()
        #expect(vm.smbServers.contains { $0.id == keep })
        #expect(vm.smbServers.contains { $0.id == drop })
        let revisionBefore = router.libraryRevision

        await vm.removeSMBServer(drop)

        // The published list the settings server-list renders must drop the removed server
        // immediately — the bug was the row lingering until Settings was closed and reopened.
        #expect(vm.smbServers.contains { $0.id == drop } == false)
        // The surviving server stays put.
        #expect(vm.smbServers.contains { $0.id == keep })
        // And the sidebar reload signal fired (the same revision bump the roots rebuild on).
        #expect(router.libraryRevision > revisionBefore)
    }

    @Test("removeSMBServer clearing the last source routes the empty config back to login")
    func removeLastServerRoutesToLogin() async throws {
        let store = makeStore()
        let router = AppRouter()
        let only = try await store.addSMBServer(smbData(host: "only.local"), password: "pw")

        let vm = makeViewModel(store: store, router: router)
        await vm.refresh()
        #expect(vm.smbServers.count == 1)

        await vm.removeSMBServer(only)

        #expect(vm.smbServers.isEmpty)
        // No source left → the router falls back to login (the SMB-only teardown path).
        #expect(router.hasAnySource == false)
        #expect(router.destination == .login)
    }
}

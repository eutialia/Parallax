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
    private func makeStore() -> ServerStore {
        makeIsolatedServerStore(label: "SettingsViewModelTests")
    }

    /// `SettingsViewModel` requires a `SessionManager`, but the SMB-removal path never reaches the
    /// network — `UnusedJellyfinClientFactory` traps if it ever does.
    private func makeViewModel(store: ServerStore, router: AppRouter) -> SettingsViewModel {
        SettingsViewModel(
            sessionManager: SessionManager(serverStore: store, factory: UnusedJellyfinClientFactory()),
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
        // Baseline the reload key with BOTH servers configured, so the assertion below is about the
        // removal rather than about the router leaving its pristine pre-launch state.
        await vm.reloadAfterSMBChange()
        let tokenWithBothServers = router.libraryReloadToken

        await vm.removeSMBServer(drop)

        // The published list the settings server-list renders must drop the removed server
        // immediately — the bug was the row lingering until Settings was closed and reopened.
        #expect(vm.smbServers.contains { $0.id == drop } == false)
        // The surviving server stays put.
        #expect(vm.smbServers.contains { $0.id == keep })
        // And the roots' reload key moved, so the sidebar rebuilds. Asserted on the TOKEN, not on
        // `libraryRevision`: a source add/removal now moves the token via the store's source-set
        // fingerprint, and the manual revision bump this used to check is reserved for changes to
        // the contents of an unchanged set (visible-libraries edits, SMB share re-selection).
        #expect(router.libraryReloadToken != tokenWithBothServers)
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

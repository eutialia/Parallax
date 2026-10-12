import Foundation
import ParallaxFeatures
import ParallaxJellyfin
import Testing

/// Locks in what the SMB server-settings screen relies on when it removes a server: the *published*
/// `smbServers` list refreshes immediately (and the sidebar reloads), not just the store. The bug this guards: the detail view used to remove
/// the server with its own inline copy of this logic that skipped the refresh, so the removed server
/// lingered as a ghost row in the settings server list until Settings was closed and reopened.
@Suite("Settings view model · SMB server removal")
@MainActor
struct SettingsViewModelTests {
    @Test("removing an SMB server from its settings page drops it from the server list right away — no panel reopen")
    func removeRefreshesPublishedList() async throws {
        let world = try await AppWorld.launch()
        let store = world.app.services.serverStore
        let router = world.app.router
        let keep = try await store.addSMBServer(makeSMBServerData(host: "keep.local"), password: "pw")
        let drop = try await store.addSMBServer(makeSMBServerData(host: "drop.local"), password: "pw")

        let vm = SettingsViewModel(app: world.app)
        await vm.refresh()
        #expect(vm.smbServers.contains { $0.id == keep })
        #expect(vm.smbServers.contains { $0.id == drop })
        // Baseline the reload key with BOTH servers configured, so the assertion below is about
        // the removal rather than about the router leaving its pristine pre-launch state.
        await world.app.routeToSources()
        await vm.refresh()
        let tokenWithBothServers = router.libraryReloadToken

        await world.app.makeSMBServerSettings(id: drop, data: makeSMBServerData(host: "drop.local")).remove()
        await vm.refresh()

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

    @Test("removing the last SMB server from its settings page routes the empty config back to login")
    func removeLastServerRoutesToLogin() async throws {
        let world = try await AppWorld.launch()
        let router = world.app.router
        let only = try await world.app.services.serverStore.addSMBServer(makeSMBServerData(host: "only.local"), password: "pw")

        let vm = SettingsViewModel(app: world.app)
        await world.app.routeToSources()
        await vm.refresh()
        #expect(vm.smbServers.count == 1)
        #expect(router.destination == .home)

        await world.app.makeSMBServerSettings(id: only, data: makeSMBServerData(host: "only.local")).remove()
        await vm.refresh()

        #expect(vm.smbServers.isEmpty)
        // No source left → the router falls back to login (the SMB-only teardown path).
        #expect(router.hasAnySource == false)
        #expect(router.destination == .login)
    }
}

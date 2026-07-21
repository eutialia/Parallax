import SwiftUI
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// Per-SMB-server settings detail (handoff 3i) — pushed from a server row in `SettingsView`.
/// Shows the server's identity header and connection address, then a live share toggle list:
/// on appear it connects and calls `listShares()`, pre-checking the persisted `data.shares`,
/// and each toggle calls `ServerStore.setShares(_:for:)` + bumps the router's library revision
/// so the sidebar updates immediately. A Remove action drops the server entirely.
struct SMBServerSettingsView: View {
    let server: PersistedServer
    /// The shared settings view model (same instance the server-list root holds). Removal is handed to
    /// it so its published `smbServers` refreshes in lockstep with the store — see `removeServer()`.
    let vm: SettingsViewModel

    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var isConfirmingRemove = false

    // MARK: - Share list state

    enum LoadState {
        case loading
        case loaded([SMBShare])
        case failed(String)
    }

    @State private var loadState: LoadState = .loading
    /// The set of share names currently toggled on (synced from persisted data on load).
    @State private var enabledShares: Set<String> = []
    /// The lister, held for disconnect on disappear.
    @State private var lister: AMSMB2Lister?
    /// Serialises share-toggle writes so rapid taps persist in tap order — an unordered `Task` per
    /// tap can let a stale snapshot land last, desyncing the store from the on-screen circles.
    @State private var saveTask: Task<Void, Never>?

    // MARK: - Derived

    private var data: SMBServerData? {
        if case .smb(let d) = server.kind { return d } else { return nil }
    }

    private var host: String { data?.host ?? "" }

    private var account: String {
        guard let data, !data.username.isEmpty else { return "Guest" }
        return data.username
    }

    private var connectionPill: StatusPillData {
        switch loadState {
        case .loading:
            return StatusPillData(lead: .led(Color.tertiaryLabel), text: "Connecting…")
        case .failed:
            return StatusPillData(lead: .led(Color.destructive), text: "Can't connect")
        case .loaded:
            return StatusPillData(lead: .led(Color.ok), text: "Connected")
        }
    }

    // MARK: - Body

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            ServerIdentityHero(
                systemImage: "externaldrive.badge.wifi",
                name: host,
                meta: "SMB · \(host)",
                pills: [
                    connectionPill,
                    StatusPillData(lead: .symbol("person"), text: account),
                ]
            )

            SettingsGroup(title: "Connection") {
                SettingsRowLabel(
                    systemImage: "externaldrive.badge.wifi",
                    title: "Address",
                    value: "smb://\(host)"
                )
            }

            sharesSection

            SettingsGroup {
                SettingsListRow(systemImage: "trash", title: "Remove Server", role: .destructive) {
                    isConfirmingRemove = true
                }
            }
        }
        .navigationTitle(host)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await loadShares() }
        .onDisappear { Task { await lister?.disconnect() } }
        .confirmationDialog(
            "Remove this server?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await removeServer() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(host) will be removed from your libraries.")
        }
    }

    // MARK: - Shares section

    @ViewBuilder
    private var sharesSection: some View {
        SettingsGroup(title: "Shares", footer: sharesFooter) {
            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)

            case .failed(let message):
                SettingsRetryError(message: message) { Task { await loadShares() } }

            case .loaded(let shares):
                loadedShares(shares)
            }
        }
    }

    /// Group footer — gains a recovery hint only while at least one unavailable row is on screen, so
    /// the "turn it off to remove" affordance is spelled out exactly when it applies (and never when
    /// every share is live).
    private var sharesFooter: String {
        let base = "Choose which shares on this server appear as libraries in Parallax."
        if case .loaded(let shares) = loadState,
           !Self.unavailableShares(enabled: enabledShares, live: shares).isEmpty {
            return base + " Turn off an unavailable share to remove its library."
        }
        return base
    }

    /// The live shares as selectable rows, then any enabled-but-absent share (removed/renamed
    /// server-side) as an "unavailable" row the user can switch OFF to drop the now-dead library —
    /// the union closes the trap where such a share is invisible in settings yet still mounted as a
    /// failing sidebar tab, removable only by deleting the whole server.
    @ViewBuilder
    private func loadedShares(_ shares: [SMBShare]) -> some View {
        let unavailable = Self.unavailableShares(enabled: enabledShares, live: shares)
        if shares.isEmpty && unavailable.isEmpty {
            SettingsSectionFooter("No shares found on this server.")
        } else {
            ForEach(shares, id: \.name) { share in
                ShareSelectionRow(
                    share: share,
                    isSelected: enabledShares.contains(share.name)
                ) { toggle(share.name) }
            }
            ForEach(unavailable, id: \.self) { name in
                ShareSelectionRow(
                    share: SMBShare(name: name, comment: ""),
                    isSelected: true,
                    isUnavailable: true
                ) { toggle(name) }
            }
        }
    }

    // MARK: - Logic

    private func loadShares() async {
        guard let data else { return }
        if let existing = lister { await existing.disconnect() }
        loadState = .loading
        let ref = SMBServerRef(id: server.id, data: data)
        do {
            let newLister = try await deps.makeSMBLister(ref)
            lister = newLister
            let fetched = try await newLister.listShares()
            let sorted = fetched.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            // Seed the toggles from the LIVE store, not the navigation snapshot: `server` is captured
            // when the row is tapped and the parent's list isn't refreshed on a toggle, so re-entering
            // this screen after toggling would otherwise revert the circles to the stale snapshot.
            enabledShares = await persistedShares()
            loadState = .loaded(sorted)
        } catch {
            // One classification for both throw sites: makeSMBLister's pre-flight already yields a
            // typed AppError (lost Keychain slot — never reached the server), and listShares' raw
            // POSIX failures go through the shared mapper. Either way, auth-shaped faults get the
            // credential recovery instead of a generic host message that reads as connectivity.
            let appError = (error as? AppError) ?? SMBFileSource.mapShareListError(error, host: host)
            switch appError {
            case .auth(.credentialUnavailable):
                loadState = .failed(appError.userMessage)
            case .auth:
                loadState = .failed("\(host) rejected the sign-in. Remove this server and add it again to update the password.")
            default:
                loadState = .failed("Couldn't load shares from \(host).")
            }
        }
    }

    /// The shares currently persisted for this server, read fresh from the store (the source of
    /// truth). Falls back to the navigation snapshot if the server was removed out from under us.
    private func persistedShares() async -> Set<String> {
        let current = await deps.serverStore.servers.first { $0.id == server.id }
        if case .smb(let d) = current?.kind { return Set(d.shares) }
        return Set(data?.shares ?? [])
    }

    private func toggle(_ name: String) {
        let wasOn = enabledShares.contains(name)
        if wasOn { enabledShares.remove(name) } else { enabledShares.insert(name) }
        let snapshot = enabledShares.sorted()
        let id = server.id
        // Chain off the previous write so concurrent toggles persist in tap order — an independent
        // Task per tap isn't ordered, so a stale snapshot could land last and desync the store.
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            do {
                try await deps.serverStore.setShares(snapshot, for: id)
                // Rebuild the merged library list so the sidebar updates immediately — same call as
                // VisibleLibrariesView uses for Jellyfin collection toggles.
                router.bumpLibraryRevision()
            } catch {
                // Persist failed — revert the optimistic toggle so the circle matches what's stored.
                if wasOn { enabledShares.insert(name) } else { enabledShares.remove(name) }
            }
        }
    }

    /// Hand removal to the shared settings view model so its published server list refreshes in lockstep
    /// with the store + sidebar. The view used to carry its own copy of this (store remove + router
    /// re-evaluate) that never refreshed the parent's `smbServers`, so the removed server lingered as a
    /// ghost row in the settings list until the panel was torn down and reopened. Always dismiss after:
    /// if it was the last source the router tears the panel down (a no-op pop); otherwise this pops off
    /// the detail page of a server that no longer exists.
    private func removeServer() async {
        await vm.removeSMBServer(server.id)
        dismiss()
    }
}

// MARK: - Share reconciliation

extension SMBServerSettingsView {
    /// The enabled-but-absent share names: persisted/enabled shares the live `listShares()` no longer
    /// returns (removed or renamed server-side). Sorted for a stable row order. Rendered as
    /// "unavailable" rows so the user can switch them off and drop the dead library — without this they
    /// stay invisible in settings yet mounted as a failing sidebar tab. NOT auto-pruned: this is only
    /// computed in the `.loaded` state, so a transient connect blip (which surfaces `.failed`) never
    /// silently drops a momentarily-missing share.
    static func unavailableShares(enabled: Set<String>, live: [SMBShare]) -> [String] {
        enabled.subtracting(live.map(\.name)).sorted()
    }
}

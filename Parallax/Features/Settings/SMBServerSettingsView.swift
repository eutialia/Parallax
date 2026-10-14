import SwiftUI
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxFeatures

/// Per-SMB-server settings detail (handoff 3i) — pushed from a server row in `SettingsView`.
/// Shows the server's identity header and connection address, then a live share toggle list
/// (`SMBServerSettingsModel`): on appear it lists the shares, pre-checking the persisted ones, and
/// each toggle persists + rebuilds the sidebar. A Remove action drops the server entirely.
struct SMBServerSettingsView: View {
    let server: PersistedServer
    /// The shared settings view model (same instance the server-list root holds), refreshed after a
    /// removal so its `smbServers` list drops the row — see `removeServer()`.
    let vm: SettingsViewModel
    /// Pops this page. Not `\.dismiss`, for the render loop described on `ServerSettingsView.onRemoved`.
    let onRemoved: () -> Void

    @Environment(AppModel.self) private var app
    @State private var model: SMBServerSettingsModel?

    @State private var isConfirmingRemove = false
    /// Drives the pushed password-recovery form (same `navigationDestination(isPresented:)` idiom
    /// the add-server form uses for its share picker).
    @State private var isEnteringPassword = false

    private var loadState: SMBServerSettingsModel.LoadState { model?.loadState ?? .loading }
    private var enabledShares: Set<String> { model?.enabledShares ?? [] }

    // MARK: - tvOS focus

    /// Which share row holds focus, keyed by share name. Driven PROGRAMMATICALLY when the load
    /// settles (see `relocateFocus`) — while shares load, "Remove Server" is the screen's ONLY
    /// focusable row, so focus parks at the bottom and the rows that appear above it get nothing.
    /// Unused on iOS: the rows bind through `tvFocused`, which is a no-op there.
    @FocusState private var focusedShare: String?
    /// The failure state's Retry button, same relocation contract as `focusedShare`.
    @FocusState private var retryFocused: Bool

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
        .task {
            if model == nil, let data { model = app.makeSMBServerSettings(id: server.id, data: data) }
            await model?.loadShares()
        }
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
        .navigationDestination(isPresented: $isEnteringPassword) {
            if let data {
                SMBPasswordRecoveryView(id: server.id, data: data) {
                    isEnteringPassword = false
                    // The password is live again — re-run the share load that failed.
                    Task { await model?.loadShares() }
                }
                .tvHidesTabSidebar()
            }
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

            case .failed(let message, let offersPasswordRecovery):
                SettingsRetryError(message: message, retryFocus: $retryFocused) {
                    Task { await model?.loadShares() }
                }
                if offersPasswordRecovery {
                    // In-place recovery instead of the old remove-and-re-add dead end: the row
                    // already knows the host, account and shares — only the secret is missing.
                    SettingsListRow(systemImage: "key", title: "Enter Password…") {
                        isEnteringPassword = true
                    }
                }

            case .loaded(let shares):
                loadedShares(shares)
            }
        }
        // One traversal unit, so a vertical walk crosses the share rows in order and leaves the group
        // at its edges instead of the focus engine picking a geometric neighbour mid-list.
        .tvFocusSection()
        #if os(tvOS)
        // RENDERED side, not the load path: `loadShares()` used to call `relocateFocus` itself, in
        // the same main-actor turn that assigns `loadState` — before SwiftUI has committed the rows
        // that the write targets, so a `@FocusState` write with no matching bound view is dropped
        // silently. `.onChange` fires off the state SwiftUI itself just applied to this rendered
        // subtree, so the target rows are guaranteed to exist by the time it runs. (A `.task(id:)`
        // here would work too, but it's the wrong tool: this isn't async work keyed to an identity,
        // it's a plain "state changed, react once" hook — `.onChange` is what `HomeHeroCarousel` uses
        // for the same shape, e.g. its `entries.map(\.id)` reset.) tvOS-ONLY, and compiled out
        // everywhere else: unlike `focusedShare`/`retryFocused`'s bindings (already no-ops off tvOS
        // via `tvFocused`), this block is the thing that WRITES them — iPhone/iPad never run the
        // write at all, since there's no reason to fire an inert relocation on every load.
        .onChange(of: loadState) { _, newValue in
            relocateFocus(to: SMBServerSettingsModel.focusTarget(for: newValue, enabled: enabledShares))
        }
        #endif
    }

    /// Group footer — gains a recovery hint only while at least one unavailable row is on screen, so
    /// the "turn it off to remove" affordance is spelled out exactly when it applies (and never when
    /// every share is live).
    private var sharesFooter: String {
        let base = "Choose which shares on this server appear as libraries in Parallax."
        if case .loaded(let shares) = loadState,
           !SMBServerSettingsModel.unavailableShares(enabled: enabledShares, live: shares).isEmpty {
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
        let unavailable = SMBServerSettingsModel.unavailableShares(enabled: enabledShares, live: shares)
        if shares.isEmpty && unavailable.isEmpty {
            SettingsSectionFooter("No shares found on this server.")
        } else {
            ForEach(shares, id: \.name) { share in
                ShareSelectionRow(
                    share: share,
                    isSelected: enabledShares.contains(share.name)
                ) { model?.toggle(share.name) }
                    .tvFocused($focusedShare, equals: share.name)
            }
            ForEach(unavailable, id: \.self) { name in
                ShareSelectionRow(
                    share: SMBShare(name: name, comment: ""),
                    isSelected: true,
                    isUnavailable: true
                ) { model?.toggle(name) }
                    .tvFocused($focusedShare, equals: name)
            }
        }
    }

    // MARK: - Logic

    /// Move focus into the shares group once its rows exist. Required, not decorative: while the load
    /// runs the screen's only focusable view is the bottom "Remove Server" row, so focus parks there
    /// and the rows that appear ABOVE it inherit nothing — DOWN is a dead press and the list is only
    /// reachable by pressing UP. A declarative `prefersDefaultFocus`/`resetFocus` can't fix that (both
    /// only re-resolve WITHIN a scope that already holds focus), so the move is explicit. Deferred a
    /// runloop for the same reason as `HomeHeroCarousel`'s hero grab: even triggered from `.onChange`
    /// (the rendered side — see `sharesSection`), the write still needs to land AFTER SwiftUI finishes
    /// committing this transaction's view updates, not synchronously inside the callback.
    private func relocateFocus(to target: SMBServerSettingsModel.ShareFocusTarget?) {
        guard let target else { return }
        Task { @MainActor in
            switch target {
            case .row(let name): focusedShare = name
            case .retry: retryFocused = true
            }
        }
    }

    /// Removes the server, then refreshes the shared settings list so the row goes with it (a list
    /// that isn't refreshed keeps a ghost row until the panel is reopened). Always pop after: if
    /// it was the last source the router tears the panel down (a no-op pop); otherwise this pops off
    /// the detail page of a server that no longer exists.
    private func removeServer() async {
        await model?.remove()
        await vm.refresh()
        onRemoved()
    }
}

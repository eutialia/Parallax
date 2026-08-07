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

    /// `Equatable` (auto-synthesized: `[SMBShare]` is `Equatable` via `SMBShare: Hashable`, `String`
    /// already is) so `.onChange(of:)` below can key off it directly — no derived discriminator
    /// needed, the payload-carrying cases are cheap and correct to compare as-is.
    enum LoadState: Equatable {
        case loading
        case loaded([SMBShare])
        case failed(String)
    }

    @State private var loadState: LoadState = .loading
    /// The set of share names currently toggled on (synced from persisted data on load).
    @State private var enabledShares: Set<String> = []
    /// Serialises share-toggle writes so rapid taps persist in tap order — an unordered `Task` per
    /// tap can let a stale snapshot land last, desyncing the store from the on-screen circles.
    @State private var saveTask: Task<Void, Never>?
    /// Monotonic token so only the LATEST share load may write state. Retry stays tappable while a
    /// load runs, so two loads can overlap — and they resolve in arrival order, not start order, so
    /// without this an older answer can land last and show a stale list (or a failure the newer,
    /// successful load already cleared).
    @State private var loadGeneration = 0

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
        .task { await loadShares() }
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
                SettingsRetryError(message: message, retryFocus: $retryFocused) {
                    Task { await loadShares() }
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
            relocateFocus(to: Self.focusTarget(for: newValue, enabled: enabledShares))
        }
        #endif
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
                    .tvFocused($focusedShare, equals: share.name)
            }
            ForEach(unavailable, id: \.self) { name in
                ShareSelectionRow(
                    share: SMBShare(name: name, comment: ""),
                    isSelected: true,
                    isUnavailable: true
                ) { toggle(name) }
                    .tvFocused($focusedShare, equals: name)
            }
        }
    }

    // MARK: - Logic

    private func loadShares() async {
        guard let data else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        let ref = SMBServerRef(id: server.id, data: data)
        do {
            let fetched = try await deps.makeSMBLister(ref).listShares()
            let sorted = fetched.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            // Seed the toggles from the LIVE store, not the navigation snapshot: `server` is captured
            // when the row is tapped and the parent's list isn't refreshed on a toggle, so re-entering
            // this screen after toggling would otherwise revert the circles to the stale snapshot.
            let persisted = await persistedShares()
            guard generation == loadGeneration, !Task.isCancelled else { return }
            enabledShares = persisted
            loadState = .loaded(sorted)
        } catch {
            // A disappearing view cancels this task; its error must not paint a stale failure state
            // over whatever the next appearance loads.
            guard !Task.isCancelled else { return }
            // One classification for both throw sites: makeSMBLister's pre-flight already yields a
            // typed AppError (lost Keychain slot — never reached the server), and listShares' raw
            // POSIX failures go through the shared mapper. Either way, auth-shaped faults get the
            // credential recovery instead of a generic host message that reads as connectivity.
            let appError = (error as? AppError) ?? SMBFileSource.mapShareListError(error, host: host)
            let message: String
            switch appError {
            case .auth(.credentialUnavailable):
                message = appError.userMessage
            case .auth:
                message = "\(host) rejected the sign-in. Remove this server and add it again to update the password."
            default:
                message = "Couldn't load shares from \(host)."
            }
            guard generation == loadGeneration else { return }
            loadState = .failed(message)
        }
    }

    /// Move focus into the shares group once its rows exist. Required, not decorative: while the load
    /// runs the screen's only focusable view is the bottom "Remove Server" row, so focus parks there
    /// and the rows that appear ABOVE it inherit nothing — DOWN is a dead press and the list is only
    /// reachable by pressing UP. A declarative `prefersDefaultFocus`/`resetFocus` can't fix that (both
    /// only re-resolve WITHIN a scope that already holds focus), so the move is explicit. Deferred a
    /// runloop for the same reason as `HomeHeroCarousel`'s hero grab: even triggered from `.onChange`
    /// (the rendered side — see `sharesSection`), the write still needs to land AFTER SwiftUI finishes
    /// committing this transaction's view updates, not synchronously inside the callback.
    private func relocateFocus(to target: ShareFocusTarget?) {
        guard let target else { return }
        Task { @MainActor in
            switch target {
            case .row(let name): focusedShare = name
            case .retry: retryFocused = true
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

// MARK: - Share reconciliation + focus targeting

extension SMBServerSettingsView {
    /// Where focus should land once the shares group settles. `Equatable` so the decision below can
    /// be asserted directly.
    enum ShareFocusTarget: Equatable {
        case row(String)
        case retry
    }

    /// Where focus should land for a given `loadState` — the single source `.onChange(of: loadState)`
    /// (on `sharesSection`) and any future caller derive from, so exactly one place maps state to a
    /// focus target.
    ///
    /// Static and fully parameterised rather than reading `@State` in place: the enabled set is the
    /// only other input, so passing it makes the whole mapping a pure function the tests can drive
    /// through every branch without standing up a view.
    static func focusTarget(for state: LoadState, enabled: Set<String>) -> ShareFocusTarget? {
        switch state {
        case .loading: return nil
        case .loaded(let shares): return firstShareRow(live: shares, enabled: enabled)
        case .failed: return .retry
        }
    }

    /// The group's first focusable row after a successful load: a live share, else the leading
    /// unavailable row. Nil when the group renders only the "No shares found" footer — nothing to
    /// focus, so focus stays where the engine left it rather than being yanked somewhere arbitrary.
    static func firstShareRow(live shares: [SMBShare], enabled: Set<String>) -> ShareFocusTarget? {
        let name = shares.first?.name ?? unavailableShares(enabled: enabled, live: shares).first
        return name.map(ShareFocusTarget.row)
    }

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

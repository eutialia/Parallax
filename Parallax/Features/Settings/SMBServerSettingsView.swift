import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin

/// Per-SMB-server settings detail (handoff 3i) — pushed from a server row in `SettingsView`.
/// Shows the server's identity header and connection address, then a live share toggle list:
/// on appear it connects and calls `listShares()`, pre-checking the persisted `data.shares`,
/// and each toggle calls `ServerStore.setShares(_:for:)` + bumps the router's library revision
/// so the sidebar updates immediately. A Remove action drops the server entirely.
struct SMBServerSettingsView: View {
    let server: PersistedServer

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

    // MARK: - Derived

    private var data: SMBServerData? {
        if case .smb(let d) = server.kind { return d } else { return nil }
    }

    private var host: String { data?.host ?? "" }

    private var account: String {
        guard let data, !data.username.isEmpty else { return "Guest" }
        return data.username
    }

    // MARK: - Body

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            ServerIdentityHero(
                systemImage: "externaldrive.badge.wifi",
                name: host,
                meta: "SMB · \(host)",
                pills: [
                    StatusPillData(lead: .led(Color.ok), text: "Connected"),
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
        SettingsGroup(
            title: "Shares",
            footer: "Choose which shares on this server appear as libraries in Parallax."
        ) {
            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)

            case .failed(let message):
                SettingsRetryError(message: message) { Task { await loadShares() } }

            case .loaded(let shares):
                if shares.isEmpty {
                    SettingsSectionFooter("No shares found on this server.")
                } else {
                    ForEach(shares, id: \.name) { share in
                        ShareToggleRow(
                            share: share,
                            isOn: enabledShares.contains(share.name)
                        ) { toggle(share.name) }
                    }
                }
            }
        }
    }

    // MARK: - Logic

    private func loadShares() async {
        guard let data else { return }
        loadState = .loading
        let ref = SMBServerRef(id: server.id, data: data)
        let newLister = await deps.makeSMBLister(ref)
        lister = newLister
        do {
            let fetched = try await newLister.listShares()
            let sorted = fetched.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            enabledShares = Set(data.shares)
            loadState = .loaded(sorted)
        } catch {
            loadState = .failed("Couldn't load shares from \(host).")
        }
    }

    private func toggle(_ name: String) {
        let wasOn = enabledShares.contains(name)
        if wasOn { enabledShares.remove(name) } else { enabledShares.insert(name) }
        let snapshot = enabledShares.sorted()
        let id = server.id
        Task {
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

    /// Remove the server from the store and re-evaluate routing (same logic as
    /// `SettingsViewModel.removeSMBServer` + `reloadAfterSMBChange`).
    private func removeServer() async {
        do { try await deps.serverStore.remove(server.id) } catch {}
        // Re-read the store to determine the updated sources state for routing.
        let remaining = await deps.serverStore.servers
        let activeSession = await deps.serverStore.active
        let hasAux = remaining.contains { if case .smb = $0.kind { return true }; return false }
        router.updateForSources(activeSession: activeSession, hasAuxiliarySources: hasAux)
        router.bumpLibraryRevision()
        dismiss()
    }
}

// MARK: - Share toggle row

/// One share row in the toggle list: a leading `SelectionCircle` + drive icon + name + optional comment.
private struct ShareToggleRow: View {
    let share: SMBShare
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.s12) {
                SelectionCircle(state: isOn ? .on : .off)

                HStack(spacing: Space.s12) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.secondaryLabel)
                        .frame(width: SettingsListRow.glyphColumnWidth, alignment: .center)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(share.name)
                            .font(.rowBody)
                            .foregroundStyle(Color.label)
                            .lineLimit(1)
                        if !share.comment.isEmpty {
                            Text(share.comment)
                                .font(.rowSubtitle)
                                .foregroundStyle(Color.secondaryLabel)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Space.s12)
                }
                .contentShape(.rect)
            }
            .padding(.horizontal, SettingsMetrics.rowHInset)
            .padding(.vertical, Space.s12)
            .frame(minHeight: SettingsListRow.rowMinHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .tvListRowButton()
        .accessibilityValue(isOn ? "Enabled" : "Disabled")
    }
}

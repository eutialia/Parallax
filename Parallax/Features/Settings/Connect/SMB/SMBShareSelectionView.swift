import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin

/// Multi-select share picker shown after a successful `listShares()`. Each `SMBShare` returned
/// by the server is presented as a toggleable row; the user picks which shares to mount as
/// libraries. Confirming calls `ServerStore.addSMBServer` with the selected share names, then
/// disconnects the lister and fires `onAdded`.
///
/// `lister.disconnect()` runs in `onDisappear` regardless of how the view leaves (back, success,
/// or app background); the lister is an actor, so it's always safe from MainActor context.
struct SMBShareSelectionView: View {
    let lister: AMSMB2Lister
    let host: String
    let username: String
    let password: String
    let domain: String
    let shares: [SMBShare]
    var onAdded: () -> Void

    @Environment(AppDependencies.self) private var deps

    /// Share names that have been toggled on.
    @State private var selected: Set<String> = []
    @State private var isSaving = false
    @State private var saveError: String?

    // MARK: - Derived

    private var addButtonTitle: String {
        switch selected.count {
        case 0: return "Add Shares"
        case 1: return "Add 1 Share"
        default: return "Add \(selected.count) Shares"
        }
    }

    // MARK: - Body

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            VStack(spacing: Space.s18) {
                #if os(tvOS)
                // tvOS has no nav bar (the native pill only reads "Settings"), so the picker carries
                // its own "Choose Shares" identity inline. iOS shows the nav title instead.
                FormIntroHeader(
                    glyph: .symbol("externaldrive.badge.wifi"),
                    title: "Choose Shares",
                    subtitle: "Select one or more shares to add as libraries."
                )
                .padding(.bottom, Space.s8)
                #endif

                SettingsGroup(title: "Shares") {
                    ForEach(shares, id: \.name) { share in
                        ShareSelectRow(
                            share: share,
                            isSelected: selected.contains(share.name),
                            onToggle: { toggle(share.name) }
                        )
                    }
                }

                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(Color.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.headerInset)
                }

                Button(action: save) {
                    Text(addButtonTitle).formActionLabel(.solid, isWorking: isSaving)
                }
                .formActionButton(.solid)
                .disabled(selected.isEmpty || isSaving)
                .padding(.top, Space.s3)
            }
        }
        .navigationTitle("Choose Shares")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear {
            Task { await lister.disconnect() }
        }
    }

    // MARK: - Selection

    private func toggle(_ name: String) {
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
    }

    // MARK: - Save

    private func save() {
        guard !selected.isEmpty else { return }
        isSaving = true
        saveError = nil
        let capturedPassword = password
        Task {
            do {
                try await deps.serverStore.addSMBServer(
                    SMBServerData(host: host, username: username, domain: domain, shares: selected.sorted()),
                    password: capturedPassword
                )
                await lister.disconnect()
                onAdded()
            } catch {
                saveError = "Couldn't save the shares. Try again."
                isSaving = false
            }
        }
    }
}

/// One selectable share row: a leading `SelectionCircle` + share name + optional comment subtitle.
private struct ShareSelectRow: View {
    let share: SMBShare
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.s12) {
                SelectionCircle(state: isSelected ? .on : .off)

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
    }
}

#if DEBUG
#Preview("SMB share selector · rows", traits: .fixedLayout(width: 540, height: 600)) {
    let stubShares = [
        SMBShare(name: "Media", comment: "Movies & TV"),
        SMBShare(name: "Backups", comment: ""),
        SMBShare(name: "Photos", comment: "Family photos"),
        SMBShare(name: "Downloads", comment: ""),
    ]
    ScrollView {
        VStack(spacing: Space.s18) {
            SettingsGroup(title: "Shares") {
                ForEach(stubShares, id: \.name) { share in
                    ShareSelectRow(
                        share: share,
                        isSelected: share.name == "Media" || share.name == "Photos",
                        onToggle: {}
                    )
                }
            }
            Button {} label: { Text("Add 2 Shares").formActionLabel(.solid) }
                .formActionButton(.solid)
        }
        .padding(Space.s18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.background)
}
#endif

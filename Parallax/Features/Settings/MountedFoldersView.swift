import SwiftUI
import ParallaxJellyfin

/// "Mounted Folders" management for an SMB host (handoff 3i, the `2 folders` row's destination). Lists
/// every folder mounted from this host — each is its own `(host, share, root)` source under the grouped
/// host row — and lets the user remove them individually (the SMB detail's "Remove Server" drops them
/// all at once). Adding more folders goes through the main Add-Server → Network Share flow, which already
/// connects + multi-selects, so this screen stays focused on review + removal.
struct MountedFoldersView: View {
    let host: String
    let vm: SettingsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: PersistedServer?

    private var sources: [PersistedServer] { vm.smbSources(for: host) }

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            SettingsGroup(footer: "Each folder is its own library. Removing one stops it appearing in Parallax.") {
                ForEach(sources) { source in
                    if case .smb(let data) = source.kind {
                        Button { pendingRemoval = source } label: { folderRow(data) }
                            .tvListRowButton()
                            .accessibilityHint("Remove this folder")
                    }
                }
            }
        }
        .navigationTitle("Mounted Folders")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            "Remove this folder?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { source in
            Button("Remove", role: .destructive) {
                Task {
                    await vm.removeSMBServer(source.id)
                    // Last folder gone → the whole host is gone; pop back off this now-empty screen.
                    if sources.isEmpty { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            if case .smb(let data) = source.kind {
                Text("\(data.displayPath) will be removed from your libraries.")
            }
        }
    }

    private func folderRow(_ data: SMBServerData) -> some View {
        HStack(spacing: Space.s12) {
            Image(systemName: "folder")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: SettingsListRow.glyphColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(data.folderName)
                    .font(.rowBody)
                    .foregroundStyle(Color.label)
                    .lineLimit(1)
                Text(data.displayPath)
                    .font(.rowSubtitle)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.s12)
            Image(systemName: "trash")
                .font(.rowBody)
                .foregroundStyle(Color.destructive)
        }
        .padding(.horizontal, SettingsMetrics.rowHInset)
        .padding(.vertical, Space.s12)
        .frame(minHeight: SettingsListRow.rowMinHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .tvFocusListRow()
    }
}

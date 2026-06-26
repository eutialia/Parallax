import SwiftUI
import ParallaxJellyfin

/// Per-SMB-host settings detail (handoff 3i) — pushed from a grouped host row in `SettingsView`. All
/// the share's mounted folders are grouped under one host here: the identity header, the connection
/// address, a "Mounted Folders" row counting the roots (it pushes `MountedFoldersView` to manage them),
/// and a destructive Remove that drops every folder on this host. Mirrors `ServerSettingsView`'s
/// shell/VM split; the host string keys the VM's SMB sources.
struct SMBServerSettingsView: View {
    let host: String
    let vm: SettingsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemove = false
    @State private var showingMountedFolders = false

    /// Every persisted SMB source on this host (one per mounted folder).
    private var sources: [PersistedServer] { vm.smbSources(for: host) }

    private var folderCount: Int { sources.count }

    /// The account shown on the status pill — the first non-empty username, else "Guest".
    private var account: String {
        for source in sources {
            if case .smb(let data) = source.kind, !data.username.isEmpty { return data.username }
        }
        return "Guest"
    }

    private var address: String { "smb://\(host)" }
    private var folderCountLabel: String { folderCount == 1 ? "1 folder" : "\(folderCount) folders" }

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            ServerIdentityHero(
                systemImage: "externaldrive.badge.wifi",
                name: host,
                // "SMB · host" — the scheme lives on the Connection row's Address (smb://host); repeating
                // it here as "SMB · smb://host" double-labelled the protocol.
                meta: "SMB · \(host)",
                pills: [
                    StatusPillData(lead: .led(Color.ok), text: "Connected"),
                    StatusPillData(lead: .symbol("person"), text: account),
                ]
            )

            SettingsGroup(title: "Connection") {
                SettingsRowLabel(systemImage: "externaldrive.badge.wifi", title: "Address", value: address)
            }

            SettingsGroup(
                title: "Folders",
                footer: "Choose which folders on this share appear as libraries in Parallax."
            ) {
                SettingsListRow(
                    systemImage: "folder",
                    title: "Mounted Folders",
                    value: folderCountLabel,
                    accessory: .chevron
                ) { showingMountedFolders = true }
            }

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
        .navigationDestination(isPresented: $showingMountedFolders) {
            MountedFoldersView(host: host, vm: vm)
        }
        .confirmationDialog("Remove this server?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    for source in sources { await vm.removeSMBServer(source.id) }
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(host) and its \(folderCountLabel) will be removed from your libraries.")
        }
    }
}

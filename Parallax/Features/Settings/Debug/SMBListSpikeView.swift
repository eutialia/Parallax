#if DEBUG
import SwiftUI
import ParallaxFileBrowse

/// Throwaway Phase-2 spike: does `AMSMB2Lister` enumerate the real NAS over SMB2/3?
/// Mirrors `SMBPlaybackSpikeView` but exercises directory listing instead of playback.
/// DELETE at the end of Phase 2 (Task 12).
///
/// Credentials are passed straight into `AMSMB2Lister` (which wraps them in a
/// `URLCredential`) — they never appear in the smb:// URL string or in any log output.
struct SMBListSpikeView: View {
    @State private var host = ""
    @State private var share = ""
    @State private var path = ""          // relative to the share root; "" lists the root
    @State private var user = ""
    @State private var password = ""
    @State private var domain = "WORKGROUP"
    @State private var status = "idle"
    @State private var entries: [SMBDirectoryEntry] = []

    var body: some View {
        Form {
            Section("Target") {
                TextField("Host (e.g. 192.168.1.10)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Share", text: $share)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Path within share (blank = root)", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Credentials") {
                TextField("Username", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                TextField("Domain", text: $domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Result") {
                Text(status).monospaced()
            }
            Section {
                Button("List directory", action: list)
            }
            if !entries.isEmpty {
                Section("Entries (\(entries.count))") {
                    ForEach(entries, id: \.self) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
        .navigationTitle("SMB List Spike")
    }

    // MARK: - Row

    private func entryRow(_ entry: SMBDirectoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                Text(entry.name).bold()
            }
            Text("\(entry.isDirectory ? "dir" : "file") · \(formatSize(entry.size)) · \(formatDate(entry.modifiedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospaced()
        }
    }

    // MARK: - Actions

    private func list() {
        status = "listing…"
        entries = []
        // Password goes straight into the lister's URLCredential; never logged / never in a URL.
        let lister = AMSMB2Lister(host: host, username: user, password: password, domain: domain)
        Task {
            do {
                let result = try await lister.list(share: share, path: path)
                await lister.disconnect()
                await MainActor.run {
                    entries = result
                    status = "ok — \(result.count) entr\(result.count == 1 ? "y" : "ies")"
                }
            } catch {
                await lister.disconnect()
                await MainActor.run {
                    status = "error: \(error)"
                }
            }
        }
    }

    // MARK: - Formatting

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SMBListSpikeView()
    }
}
#endif

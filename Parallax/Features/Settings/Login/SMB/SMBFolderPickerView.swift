import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin

/// Navigable directory browser for selecting the SMB library root.
///
/// The lister is already connected (validated by `SMBLoginView`). This view descends
/// into subdirectories and offers "Use This Folder" at every level — including the
/// share root itself (path == "").
///
/// On selection:
///   1. Builds `SMBServerData` from the captured credentials + chosen path.
///   2. Calls `deps.serverStore.addSMBServer(_:password:)`.
///   3. Calls `onAdded()` — which calls `viewModel.refresh()` + pops to root.
///      Intentionally does NOT re-point the router; SMB servers have no `Session`,
///      so the active Jellyfin session (and the router) is unchanged.
///
/// `lister.disconnect()` is called in `onDisappear` — regardless of how the view
/// leaves (back, success, or app background). The lister is an actor, so this is
/// always safe from MainActor context.
struct SMBFolderPickerView: View {
    let lister: AMSMB2Lister
    let host: String
    let share: String
    let username: String
    let password: String
    let domain: String
    var onAdded: () -> Void

    @Environment(AppDependencies.self) private var deps

    /// Current path relative to the share root. Empty = share root.
    @State private var currentPath: String = ""
    @State private var entries: [SMBDirectoryEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var saveError: String?

    private var displayPath: String {
        currentPath.isEmpty ? "/" : "/\(currentPath)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // "Use This Folder" pinned at the top so it's always reachable.
            useFolderButton
                .padding(Space.s18)

            if let error = saveError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Space.s18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                VStack(spacing: Space.s12) {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color.secondaryLabel)
                        .multilineTextAlignment(.center)
                    Button("Retry") { loadCurrentDirectory() }
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Space.s30)
            } else {
                directoryList
            }
        }
        .navigationTitle("Choose Folder")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(displayPath)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .task { loadCurrentDirectory() }
        .onDisappear {
            loadTask?.cancel()
            Task { await lister.disconnect() }
        }
    }

    // MARK: - Directory list

    private var directoryList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Filter directories once per body pass, not twice (ForEach + empty-state check).
                let dirs = entries.filter { $0.isDirectory }
                if !currentPath.isEmpty {
                    Button {
                        ascend()
                    } label: {
                        HStack(spacing: Space.s12) {
                            Image(systemName: "arrow.up.left")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)
                            Text("Parent Folder")
                                .font(.body)
                                .foregroundStyle(Color.label)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Space.s14)
                        .frame(minHeight: 48)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, Space.s14 + 20 + Space.s12)
                }

                ForEach(dirs, id: \.name) { entry in
                    Button {
                        descend(into: entry.name)
                    } label: {
                        HStack(spacing: Space.s12) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)
                            Text(entry.name)
                                .font(.body)
                                .foregroundStyle(Color.label)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .scaledFont(13, relativeTo: .footnote, weight: .semibold)
                                .foregroundStyle(Color.tertiaryLabel)
                        }
                        .padding(.horizontal, Space.s14)
                        .frame(minHeight: 48)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, Space.s14 + 20 + Space.s12)
                }

                if dirs.isEmpty {
                    Text("No subdirectories — use this folder")
                        .font(.callout)
                        .foregroundStyle(Color.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .padding(Space.s30)
                }
            }
            .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(Space.s18)
        }
    }

    // MARK: - Use This Folder

    private var useFolderButton: some View {
        Button {
            saveServer(root: currentPath)
        } label: {
            Label("Use This Folder", systemImage: "checkmark.circle.fill")
                .formActionLabel(.solid, isWorking: isSaving)
        }
        .formActionButton(.solid)
        .disabled(isSaving)
    }

    // MARK: - Navigation

    private func descend(into name: String) {
        let next = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
        currentPath = next
        entries = []
        loadCurrentDirectory()
    }

    /// Move up one level; parent of "a/b/c" is "a/b", parent of "a" is the share root "".
    private func ascend() {
        guard !currentPath.isEmpty else { return }
        if let slash = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[..<slash])
        } else {
            currentPath = ""
        }
        entries = []
        loadCurrentDirectory()
    }

    // MARK: - Loading

    private func loadCurrentDirectory() {
        isLoading = true
        loadError = nil
        let path = currentPath
        let share = share
        // Cancel any in-flight load and guard the post-await writes on `path == currentPath`:
        // rapid descend/ascend taps otherwise leave concurrent lists racing to overwrite
        // `entries`, and a slow earlier load landing last would show the wrong directory's
        // contents — then "Use This Folder" would save the wrong root.
        loadTask?.cancel()
        loadTask = Task {
            do {
                let result = try await lister.list(share: share, path: path)
                guard !Task.isCancelled, path == currentPath else { return }
                entries = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                guard !Task.isCancelled, path == currentPath else { return }
                loadError = "Couldn't list directory. \(error.localizedDescription)"
            }
            if path == currentPath { isLoading = false }
        }
    }

    // MARK: - Save

    private func saveServer(root: String) {
        isSaving = true
        saveError = nil
        let data = SMBServerData(
            host: host,
            share: share,
            root: root,
            username: username,
            domain: domain
        )
        let capturedPassword = password
        Task {
            do {
                try await deps.serverStore.addSMBServer(data, password: capturedPassword)
                // Disconnect before the view disappears (onAdded pops the stack).
                await lister.disconnect()
                onAdded()
            } catch {
                saveError = "Couldn't save the server. Try again."
                isSaving = false
            }
        }
    }
}

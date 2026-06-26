import SwiftUI
import ParallaxFileBrowse
import ParallaxJellyfin

/// Multi-select folder → library picker (handoff 3g). The connected share is browsed level by level;
/// EACH chosen path becomes its own library. A breadcrumb shows where you are, "This Folder" offers the
/// current directory as a library, and "Inside …" lists the children — each with a selection circle
/// (toggle it into the library set) and a chevron (open it to go deeper). A parent that isn't itself
/// chosen but has chosen descendants shows the indeterminate (dash) circle. The primary button counts
/// the selection: "Add N Libraries".
///
/// On confirm each selected path is written as its own `SMBServerData(host, share, root:)` — the same
/// per-`(host, share, root)` source the settings root groups back under one host row.
///
/// `lister.disconnect()` runs in `onDisappear` regardless of how the view leaves (back, success, or
/// app background); the lister is an actor, so it's always safe from MainActor context.
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
    /// Chosen paths (relative to the share root) — each becomes its own library.
    @State private var selected: Set<String> = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var saveError: String?

    // MARK: - Derived

    private var childDirectories: [SMBDirectoryEntry] {
        entries.filter(\.isDirectory)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var pathComponents: [String] {
        currentPath.isEmpty ? [] : currentPath.split(separator: "/").map(String.init)
    }

    private var currentFolderName: String { pathComponents.last ?? share }

    /// The absolute-looking path shown on the "This Folder" row, e.g. `/Media/Anime`.
    private var currentDisplayPath: String {
        SMBServerData.displayPath(share: share, root: currentPath)
    }

    private func childRoot(_ name: String) -> String {
        currentPath.isEmpty ? name : "\(currentPath)/\(name)"
    }

    /// A path's circle state: chosen itself (`on`), some descendant chosen (`mixed`), or neither (`off`).
    private func selectionState(for root: String) -> SelectionCircle.SelectionState {
        if selected.contains(root) { return .on }
        // At the share root (root == "") every relative path is a descendant, so match the empty prefix;
        // deeper levels match "root/". The old `root + "/"` produced "/" at the share root, which no
        // relative path begins with, so the "This Folder" circle never showed the indeterminate state.
        let descendantPrefix = root.isEmpty ? "" : root + "/"
        if selected.contains(where: { $0 != root && $0.hasPrefix(descendantPrefix) }) { return .mixed }
        return .off
    }

    private func toggle(_ root: String) {
        if selected.contains(root) { selected.remove(root) } else { selected.insert(root) }
    }

    private var addButtonTitle: String {
        switch selected.count {
        case 0: return "Add Library"
        case 1: return "Add 1 Library"
        default: return "Add \(selected.count) Libraries"
        }
    }

    // MARK: - Body

    var body: some View {
        SettingsScaffold(showsBrand: false) {
            #if os(tvOS)
            // tvOS has no nav bar (the native pill only reads "Settings"), so the picker carries its own
            // "Choose Libraries" identity inline (handoff `.fhead`). The live path stays in the breadcrumb
            // below — only the instruction goes in the subtitle, so the two don't duplicate. iOS shows the
            // "Choose Libraries" nav title instead.
            FormIntroHeader(
                glyph: .symbol("folder"),
                title: "Choose Libraries",
                subtitle: "Add any folder as a library, or open one to go deeper."
            )
            .padding(.bottom, Space.s8)
            #endif

            breadcrumb

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let loadError {
                SettingsRetryError(message: loadError) { loadCurrentDirectory() }
            } else {
                thisFolderSection
                insideSection
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
        .navigationTitle("Choose Libraries")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { loadCurrentDirectory() }
        .onDisappear {
            loadTask?.cancel()
            Task { await lister.disconnect() }
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: "externaldrive.badge.wifi")
                .font(.caption)
                .foregroundStyle(Color.tertiaryLabel)
            breadcrumbSegment(share, target: "", isCurrent: pathComponents.isEmpty)
            ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tertiaryLabel)
                breadcrumbSegment(
                    component,
                    target: pathComponents[0...index].joined(separator: "/"),
                    isCurrent: index == pathComponents.count - 1
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func breadcrumbSegment(_ label: String, target: String, isCurrent: Bool) -> some View {
        Button {
            if !isCurrent { descend(to: target) }
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isCurrent ? Color.label : Color.secondaryLabel)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    // MARK: - Sections

    private var thisFolderSection: some View {
        SettingsGroup(title: "This Folder", separatorInset: FolderSelectRow.separatorInset) {
            FolderSelectRow(
                state: selectionState(for: currentPath),
                name: currentFolderName,
                subtitle: currentDisplayPath,
                canDescend: false,
                onToggle: { toggle(currentPath) },
                onDescend: {}
            )
        }
    }

    @ViewBuilder
    private var insideSection: some View {
        if childDirectories.isEmpty {
            SettingsSectionFooter("No subfolders here — add this folder to make it a library.")
        } else {
            SettingsGroup(
                title: "Inside “\(currentFolderName)”",
                footer: "Add a folder to make it a library, or open it (›) to go deeper. Each path is its own library.",
                separatorInset: FolderSelectRow.separatorInset
            ) {
                ForEach(childDirectories, id: \.name) { entry in
                    let root = childRoot(entry.name)
                    FolderSelectRow(
                        state: selectionState(for: root),
                        name: entry.name,
                        subtitle: nil,
                        canDescend: true,
                        onToggle: { toggle(root) },
                        onDescend: { descend(to: root) }
                    )
                }
            }
        }
    }

    // MARK: - Navigation

    /// Jump to an absolute path within the share (breadcrumb tap or child descend).
    private func descend(to path: String) {
        guard path != currentPath else { return }
        currentPath = path
        entries = []
        loadCurrentDirectory()
    }

    // MARK: - Loading

    private func loadCurrentDirectory() {
        isLoading = true
        loadError = nil
        let path = currentPath
        let share = share
        // Cancel any in-flight load and guard post-await writes on `path == currentPath` so a slow
        // earlier list landing last can't overwrite the current directory's contents.
        loadTask?.cancel()
        loadTask = Task {
            do {
                let result = try await lister.list(share: share, path: path)
                guard !Task.isCancelled, path == currentPath else { return }
                entries = result
            } catch {
                guard !Task.isCancelled, path == currentPath else { return }
                loadError = "Couldn't list directory. \(error.localizedDescription)"
            }
            if path == currentPath { isLoading = false }
        }
    }

    // MARK: - Save

    private func save() {
        guard !selected.isEmpty else { return }
        isSaving = true
        saveError = nil
        let roots = selected.sorted()
        let capturedPassword = password
        Task {
            do {
                for root in roots {
                    let data = SMBServerData(
                        host: host,
                        share: share,
                        root: root,
                        username: username,
                        domain: domain
                    )
                    try await deps.serverStore.addSMBServer(data, password: capturedPassword)
                }
                await lister.disconnect()
                onAdded()
            } catch {
                saveError = "Couldn't save the libraries. Try again."
                isSaving = false
            }
        }
    }
}

/// One selectable folder row in the library picker: a leading selection circle (its own tap target —
/// toggles the path into the library set) and the folder body (opens the folder when it can go deeper,
/// else toggles selection). Drawn flat for the enclosing `SettingsGroup` card + hairlines.
private struct FolderSelectRow: View {
    /// Hairline inset that clears the selection circle + folder glyph (handoff `.row.pick{--sep:78px}`).
    static let separatorInset: CGFloat = 78

    let state: SelectionCircle.SelectionState
    let name: String
    var subtitle: String?
    let canDescend: Bool
    let onToggle: () -> Void
    let onDescend: () -> Void

    var body: some View {
        HStack(spacing: Space.s12) {
            Button(action: onToggle) {
                SelectionCircle(state: state)
            }
            .buttonStyle(.plain)
            .contentShape(.circle)

            Button { canDescend ? onDescend() : onToggle() } label: {
                HStack(spacing: Space.s12) {
                    Image(systemName: "folder")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.secondaryLabel)
                        .frame(width: SettingsListRow.glyphColumnWidth, alignment: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.rowBody)
                            .foregroundStyle(Color.label)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.rowSubtitle)
                                .monospacedDigit()
                                .foregroundStyle(Color.secondaryLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: Space.s12)
                    if canDescend {
                        Image(systemName: "chevron.right")
                            .font(.rowSubtitle.weight(.semibold))
                            .foregroundStyle(Color.tertiaryLabel)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SettingsMetrics.rowHInset)
        .padding(.vertical, Space.s12)
        .frame(minHeight: SettingsListRow.rowMinHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("SMB picker · rows", traits: .fixedLayout(width: 540, height: 820)) {
    ScrollView {
        VStack(spacing: Space.s18) {
            HStack(spacing: Space.s8) {
                Image(systemName: "externaldrive.badge.wifi").font(.caption).foregroundStyle(Color.tertiaryLabel)
                Text("Media").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryLabel)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.tertiaryLabel)
                Text("Anime").font(.footnote.weight(.semibold)).foregroundStyle(Color.label)
                Spacer()
            }
            .padding(.horizontal, Space.s8)

            SettingsGroup(title: "This Folder", separatorInset: FolderSelectRow.separatorInset) {
                FolderSelectRow(state: .off, name: "Anime", subtitle: "/Media/Anime",
                                canDescend: false, onToggle: {}, onDescend: {})
            }
            SettingsGroup(
                title: "Inside “Anime”",
                footer: "Add a folder to make it a library, or open it (›) to go deeper. Each path is its own library.",
                separatorInset: FolderSelectRow.separatorInset
            ) {
                FolderSelectRow(state: .on, name: "Winter 2024", canDescend: true, onToggle: {}, onDescend: {})
                FolderSelectRow(state: .on, name: "Spring 2024", canDescend: true, onToggle: {}, onDescend: {})
                FolderSelectRow(state: .mixed, name: "OVAs & Specials", canDescend: true, onToggle: {}, onDescend: {})
            }
            Button {} label: { Text("Add 2 Libraries").formActionLabel(.solid) }
                .formActionButton(.solid)
        }
        .padding(Space.s18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.background)
}
#endif

import SwiftUI

/// The Settings "Storage" group: the generated SMB thumbnail cache's on-disk size plus a Clear action.
/// Clearing forces old entries to regenerate — the way an existing thumbnail (cached before duration
/// extraction shipped, so it has no `.dur` sidecar) picks up its duration. Renders as a flat
/// `SettingsGroup` so it slots into the settings scaffold beside the Servers group, identical on both
/// platforms (the whole-card tvOS workaround is gone — the Clear row is just a normal disabled-when-
/// empty action row, with the flat focus pill every other row uses).
struct ThumbnailCacheCard: View {
    @Environment(AppDependencies.self) private var deps

    /// nil until the first size read completes; reset to 0 right after a clear.
    @State private var byteCount: Int64?
    @State private var isClearing = false
    @State private var isConfirming = false

    var body: some View {
        SettingsGroup(title: "Storage") {
            SettingsListRow(systemImage: "photo.stack", title: "Thumbnail Cache", value: sizeLabel)
            // Always pressable — never `.disabled` on the row the user just focused (disabling the
            // focused pill bounces tvOS focus to a neighbour). Clearing an empty cache is a harmless
            // idempotent no-op, so the row can stay a live focus target regardless of size.
            SettingsListRow(systemImage: "trash", title: "Clear Cache", role: .destructive) {
                isConfirming = true
            }
        }
        .task { byteCount = await deps.mediaArtworkProvider.cacheSize() }
        .confirmationDialog("Clear thumbnail cache?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { Task { await clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes generated SMB thumbnails and their durations. They regenerate as you browse.")
        }
    }

    private var sizeLabel: String {
        if isClearing { return "Clearing…" }
        guard let byteCount else { return "Calculating…" }
        return byteCount == 0 ? "Empty" : byteCount.formatted(.byteCount(style: .file))
    }

    private func clear() async {
        isClearing = true
        await deps.mediaArtworkProvider.clearCache()
        byteCount = 0
        isClearing = false
    }
}

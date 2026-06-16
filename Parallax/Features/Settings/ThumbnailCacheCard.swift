import SwiftUI

/// Settings row for the generated SMB thumbnail cache: shows its on-disk size and a Clear action.
/// Clearing forces old entries to regenerate — the way an existing thumbnail (cached before
/// duration extraction shipped, so it has no `.dur` sidecar) picks up its duration.
struct ThumbnailCacheCard: View {
    @Environment(AppDependencies.self) private var deps

    /// nil until the first size read completes; reset to 0 right after a clear.
    @State private var byteCount: Int64?
    @State private var isClearing = false
    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: Space.s14) {
            IconTile(systemImage: "photo.stack", size: 44, cornerRadius: 10, glyphSize: 18, glyphWeight: .regular)
            VStack(alignment: .leading, spacing: 2) {
                Text("Thumbnail Cache").font(.headline).foregroundStyle(Color.label)
                Text(sizeLabel).font(.caption).foregroundStyle(Color.secondaryLabel)
            }
            Spacer(minLength: 0)
            Button("Clear", role: .destructive) { isConfirming = true }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(isClearing || (byteCount ?? 0) == 0)
        }
        .padding(Space.s14)
        .glassPanel(cornerRadius: Radius.card)
        .contentShape(.rect)
        .task { byteCount = await deps.mediaArtworkProvider.cacheSize() }
        .confirmationDialog("Clear thumbnail cache?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { Task { await clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes generated SMB thumbnails and their durations. They regenerate as you browse.")
        }
        .accessibilityElement(children: .combine)
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

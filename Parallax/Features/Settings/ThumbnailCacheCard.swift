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

    /// There's something to clear — gates the action on both platforms (and the tvOS card's focus).
    private var hasContent: Bool { !isClearing && (byteCount ?? 0) > 0 }

    var body: some View {
        cardSurface
            .task { byteCount = await deps.mediaArtworkProvider.cacheSize() }
            .confirmationDialog("Clear thumbnail cache?", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { Task { await clear() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes generated SMB thumbnails and their durations. They regenerate as you browse.")
            }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cardSurface: some View {
        #if os(tvOS)
        // tvOS: the WHOLE card is the focus target — a tiny trailing "Clear" button is a poor 10-foot
        // target, and `.plain` painted a white platter on it. Pressing the focused card clears; an
        // empty cache is non-actionable (nothing to clear), so the card simply isn't focusable then.
        Button { isConfirming = true } label: {
            card(trailing: clearHint)
        }
        .tvChipButton()
        .disabled(!hasContent)
        #else
        card(trailing: clearButton)
        #endif
    }

    private func card(trailing: some View) -> some View {
        HStack(spacing: Space.s14) {
            IconTile(systemImage: "photo.stack", size: 44, cornerRadius: 10, glyphSize: 18, glyphWeight: .regular)
            VStack(alignment: .leading, spacing: 2) {
                Text("Thumbnail Cache").font(.rowTitle).foregroundStyle(Color.label)
                Text(sizeLabel).font(.rowSubtitle).foregroundStyle(Color.secondaryLabel)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(Space.s14)
        .glassPanel(cornerRadius: Radius.card)
        .contentShape(.rect)
    }

    #if os(tvOS)
    /// Trailing affordance hinting what pressing the focused card does (hidden when nothing to clear).
    @ViewBuilder
    private var clearHint: some View {
        if hasContent {
            Text("Clear")
                .font(.rowBody.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
    #else
    private var clearButton: some View {
        Button("Clear", role: .destructive) { isConfirming = true }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(!hasContent)
    }
    #endif

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

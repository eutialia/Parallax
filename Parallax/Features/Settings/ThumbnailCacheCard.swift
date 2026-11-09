import SwiftUI
import ParallaxFeatures

/// The Settings "Storage" section: the generated SMB thumbnail cache's on-disk size plus a Clear
/// action, with the handoff's explanatory footer. iOS/iPadOS render one row — title + size value + a
/// destructive "Clear" text button — matching `iph-root`. tvOS makes the WHOLE row the action ("Clear
/// Thumbnail Cache", size trailing), since the remote focuses the row, not a tiny inline button.
struct ThumbnailCacheCard: View {
    @State private var model: ThumbnailCacheModel
    @State private var isConfirming = false

    init(app: AppModel) {
        _model = State(initialValue: app.makeThumbnailCache())
    }

    var body: some View {
        SettingsGroup(
            title: "Storage",
            footer: "Cached artwork and thumbnails. Clearing won’t remove anything from your sources."
        ) {
            #if os(tvOS)
            SettingsListRow(
                systemImage: "photo.on.rectangle",
                title: "Clear Thumbnail Cache",
                value: model.sizeLabel
            ) { isConfirming = true }
            #else
            cacheRow
            #endif
        }
        .task { await model.measure() }
        .confirmationDialog("Clear thumbnail cache?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { Task { await model.clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes generated SMB thumbnails and their durations. They regenerate as you browse.")
        }
    }

    #if !os(tvOS)
    /// iOS/iPadOS Storage row: the cache title, its size, then a destructive "Clear" text button — three
    /// trailing-aligned elements on one row, so it can't reuse the generic single-accessory `SettingsRowLabel`.
    private var cacheRow: some View {
        HStack(spacing: Space.s12) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: SettingsListRow.glyphColumnWidth)
            Text("Thumbnail Cache")
                .font(.rowBody)
                .foregroundStyle(Color.label)
            Spacer(minLength: Space.s12)
            Text(model.sizeLabel)
                .font(.rowValue)
                .monospacedDigit()
                .foregroundStyle(Color.secondaryLabel)
            // Grow the ~20pt-tall text button to the 44pt HIG tap minimum without shifting the row:
            // pad out, hit-test the padded rect, reclaim the height with negative padding (the row's
            // 48pt min height absorbs the overflow). Visuals unchanged.
            Button { isConfirming = true } label: {
                Text("Clear")
                    .font(.rowValue.weight(.semibold))
                    .foregroundStyle(Color.destructive)
                    .padding(.vertical, Space.s12)
                    .contentShape(.rect)
                    .padding(.vertical, -Space.s12)
            }
            .buttonStyle(.plain)
            .padding(.leading, Space.s8)
        }
        .padding(.horizontal, SettingsMetrics.rowHInset)
        .padding(.vertical, Space.s12)
        .frame(minHeight: SettingsListRow.rowMinHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}

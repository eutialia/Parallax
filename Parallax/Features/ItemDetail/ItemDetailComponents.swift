import SwiftUI

/// A glass action pill on the detail screens (Favorite, Mark-Watched, Mark-Season-
/// Watched). The active state brightens the icon + label to `Color.label`.
/// Single source — these were byte-identical private helpers in Movie + Series detail.
struct DetailActionButton: View {
    let systemImage: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    /// Pill height scales with Dynamic Type (relative to the `.subheadline` label) so the
    /// icon + label never clip at larger text sizes.
    @ScaledMetric(relativeTo: .subheadline) private var pillHeight: CGFloat = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s8) {
                Image(systemName: systemImage)
                Text(label)
            }
            // Font on the HStack so the SF Symbol matches the label size — uniform
            // across all three detail pills (Favorite / Mark-Watched / Mark-Season).
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isActive ? Color.label : Color.secondaryLabel)
            .padding(.horizontal, Space.s14).frame(height: pillHeight)
            .glassPanel(cornerRadius: Radius.field)
        }
        .buttonStyle(.plain)
    }
}

/// A labeled metadata line (caption label over a callout value) in the detail bodies
/// (Studios, Cast & Crew, Genres).
struct DetailMetadataLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Color.secondaryLabel)
            Text(value).font(.callout).foregroundStyle(Color.label)
        }
        .padding(.horizontal, Space.s18)
    }
}

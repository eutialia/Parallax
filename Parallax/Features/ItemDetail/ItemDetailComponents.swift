import SwiftUI

/// A glass action pill on the detail screens (Favorite, Mark-Watched, Mark-Season-
/// Watched). The active state brightens the icon + label to `Color.label`.
/// Single source — these were byte-identical private helpers in Movie + Series detail.
struct DetailActionButton: View {
    let systemImage: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s8) {
                Image(systemName: systemImage)
                Text(label).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isActive ? Color.label : Color.secondaryLabel)
            .padding(.horizontal, Space.s14).frame(height: 40)
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

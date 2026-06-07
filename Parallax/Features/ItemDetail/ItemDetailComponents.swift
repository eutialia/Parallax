import SwiftUI
import ParallaxJellyfin

/// Hero metadata row: text facts, filled quality badges, and a CC indicator.
struct DetailHeroMetadataRow: View {
    let metadata: DetailMetadata

    var body: some View {
        ViewThatFits(in: .horizontal) {
            metadataRow(axis: .horizontal)
            metadataRow(axis: .vertical)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func metadataRow(axis: Axis) -> some View {
        let text = metadata.textParts.joined(separator: " · ")
        let badges = badgeRow

        switch axis {
        case .horizontal:
            HStack(spacing: Space.s8) {
                if !metadata.textParts.isEmpty {
                    Text(text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                badges
            }
        case .vertical:
            VStack(alignment: .leading, spacing: 6) {
                if !metadata.textParts.isEmpty {
                    Text(text)
                }
                badges
            }
        }
    }

    @ViewBuilder
    private var badgeRow: some View {
        if !metadata.qualityLabels.isEmpty || metadata.hasSubtitles {
            HStack(spacing: 6) {
                ForEach(metadata.qualityLabels, id: \.self) { label in
                    DetailMetadataBadge(label: label)
                }
                if metadata.hasSubtitles {
                    DetailMetadataBadge(
                        label: "CC",
                        accessibilityLabel: "Subtitles available"
                    )
                }
            }
        }
    }
}

/// Filled glass capsule for a quality or accessibility label (4K, HDR, CC, …).
/// Matches the hero's circular glass buttons — dark frosted fill over photography.
private struct DetailMetadataBadge: View {
    let label: String
    let accessibilityLabel: String

    init(label: String, accessibilityLabel: String? = nil) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel ?? label
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint(Color.heroGlass), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.heroGlassBorder, lineWidth: 1))
            .accessibilityLabel(accessibilityLabel)
            .environment(\.colorScheme, .dark)
    }
}

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

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Color.secondaryLabel)
            Text(value).font(.callout).foregroundStyle(Color.label)
        }
        .padding(.horizontal, AppLayout.contentHMargin(idiom: idiom))
    }
}

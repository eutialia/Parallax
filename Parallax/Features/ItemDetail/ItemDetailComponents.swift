import SwiftUI
import ParallaxJellyfin
import ParallaxCore

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

/// Flat filled badge for a quality or accessibility label (4K, HDR, CC, …) — radius-7
/// rounded rect + hairline, caption-bold, per the handoff. Dark `heroGlass` fill + white ink,
/// so it stays legible over the hero's photography (its only home now the ledger is plain text).
struct DetailMetadataBadge: View {
    let label: String
    let accessibilityLabel: String

    init(label: String, accessibilityLabel: String? = nil) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel ?? label
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.heroGlass, in: shape)
            .overlay(shape.strokeBorder(Color.heroGlassBorder, lineWidth: 1))
            .accessibilityLabel(accessibilityLabel)
    }
}

/// One labeled metadata block in the open-ledger metadata section. Genres render as a wrapping chip flow
/// (short tokens read better as chips across the wide card); other lists are comma-joined text.
struct DetailInfoFieldView: View {
    let field: DetailInfoField

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            DetailSectionLabel(field.label)
            switch field.presentation {
            case .chips:
                FlowLayout(spacing: Space.s8) {
                    // Index-keyed, not `id: \.self` — values can repeat (Jellyfin returns dup
                    // genres) and would collide on identity, dropping a chip.
                    ForEach(Array(field.values.enumerated()), id: \.offset) { MetadataChip(text: $0.element) }
                }
            case .text:
                Text(field.values.joined(separator: ", "))
                    .font(.detailProse)
                    .foregroundStyle(Color.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The small uppercase caption that heads a field in the open-ledger metadata section (Genres,
/// Director, Studios, …). One source so every ledger label can't drift; sizes live in TypeScale.
struct DetailSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.detailLedgerLabel)
            .textCase(.uppercase)
            .foregroundStyle(Color.secondaryLabel)
    }
}

#if DEBUG
/// Badge legibility: the dark `heroGlass` fill + white ink must stay readable over bright hero
/// photography (its only surface now the ledger renders metadata as plain text).
#Preview("Metadata badges · over artwork", traits: .sizeThatFitsLayout) {
    ZStack {
        LinearGradient(
            colors: [Color(red: 0.96, green: 0.93, blue: 0.86),
                     Color(red: 0.82, green: 0.86, blue: 0.92)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        HStack(spacing: 6) {
            DetailMetadataBadge(label: "4K")
            DetailMetadataBadge(label: "HDR")
            DetailMetadataBadge(label: "CC", accessibilityLabel: "Subtitles available")
        }
    }
    .frame(width: 360, height: 110)
}
#endif

/// A filled capsule token for a short metadata value (a genre) in the ledger. tvOS pads wider so
/// the chip breathes at 10 feet; the text sizes live in TypeScale (`detailChip`).
private struct MetadataChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.detailChip)
            .foregroundStyle(Color.label)
            .padding(.horizontal, chipHPadding)
            .padding(.vertical, chipVPadding)
            .background(Color.fill, in: Capsule())
    }

    #if os(tvOS)
    private var chipHPadding: CGFloat { Space.s18 }
    private var chipVPadding: CGFloat { Space.s12 }
    #else
    private var chipHPadding: CGFloat { Space.s12 }
    private var chipVPadding: CGFloat { Space.s8 }
    #endif
}

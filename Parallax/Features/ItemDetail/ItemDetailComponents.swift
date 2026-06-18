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
/// rounded rect + hairline, caption-bold, per the handoff. Two surfaces: `.artwork` keeps
/// the dark fill + white ink the hero needs to stay legible over photography; `.flat` uses
/// the neutral `fill` + adaptive ink for the info card's solid background.
struct DetailMetadataBadge: View {
    enum Surface { case artwork, flat }

    let label: String
    let accessibilityLabel: String
    var surface: Surface = .artwork

    init(label: String, accessibilityLabel: String? = nil, surface: Surface = .artwork) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel ?? label
        self.surface = surface
    }

    var body: some View {
        let onArtwork = surface == .artwork
        let shape = RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(onArtwork ? Color.white : Color.label)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(onArtwork ? Color.heroGlass : Color.fill, in: shape)
            .overlay(shape.strokeBorder(onArtwork ? Color.heroGlassBorder : Color.separator, lineWidth: 1))
            .accessibilityLabel(accessibilityLabel)
    }
}

/// The fact line (year · runtime · ★rating · age-rating) plus quality / CC badges, for the
/// expanded info card. The hero's `DetailHeroMetadataRow` paints white-on-photo; this variant
/// uses the adaptive label tokens so it reads on the card's flat `Color.background`.
struct DetailInfoFactsRow: View {
    let facts: DetailMetadata

    var body: some View {
        if !facts.isEmpty {
            HStack(spacing: Space.s8) {
                if !facts.textParts.isEmpty {
                    Text(facts.textParts.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondaryLabel)
                }
                // Index-keyed, not `id: \.self` — quality labels can repeat and would collide.
                ForEach(Array(facts.qualityLabels.enumerated()), id: \.offset) { DetailMetadataBadge(label: $0.element, surface: .flat) }
                if facts.hasSubtitles {
                    DetailMetadataBadge(label: "CC", accessibilityLabel: "Subtitles available", surface: .flat)
                }
            }
        }
    }
}

/// One labeled metadata block in the expanded info card. Genres render as a wrapping chip flow
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
                    .font(.callout)
                    .foregroundStyle(Color.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The small uppercase caption that heads a section/field in the detail info card (Overview,
/// Genres, Studios, …). One source so the modal's overview header and the metadata-field labels
/// can't drift.
struct DetailSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color.secondaryLabel)
    }
}

#if DEBUG
/// Badge parity: `.artwork` must stay legible over bright hero photography; `.flat` sits on
/// the solid info-card floor. Render in both schemes to check the flat-fill contrast.
#Preview("Metadata badges · artwork vs flat", traits: .sizeThatFitsLayout) {
    VStack(spacing: 0) {
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
        .frame(height: 110)
        HStack(spacing: 6) {
            DetailMetadataBadge(label: "4K", surface: .flat)
            DetailMetadataBadge(label: "HDR", surface: .flat)
            DetailMetadataBadge(label: "CC", accessibilityLabel: "Subtitles available", surface: .flat)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .background(Color.background)
    }
    .frame(width: 360)
}
#endif

/// A filled capsule token for a short metadata value (a genre) in the info card.
private struct MetadataChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.label)
            .padding(.horizontal, Space.s12)
            .padding(.vertical, Space.s8)
            .background(Color.fill, in: Capsule())
    }
}

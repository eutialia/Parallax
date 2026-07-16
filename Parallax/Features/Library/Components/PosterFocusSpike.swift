import SwiftUI

// Diagnostic screen for the poster-tile focus spike: can the NATIVE `.borderless`
// content-lockup replace `TVPosterButtonStyle` (+ the `tvFocusElevated()` zIndex hack)?
//
// History: `.borderless` was rejected because its focus highlight is masked to a SYSTEM
// corner radius that mismatched `Radius.tile` (dark corners poked out past the rounded
// art), and the lift moved the image only. The hypothesis under test (Apple docs,
// `ContentShapeKinds.hoverEffect`): `.contentShape(.hoverEffect, .rect(cornerRadius:))`
// redefines that mask shape, which would fix exactly the rejection reason — and
// `.hoverEffect(.highlight)` (tvOS 17+) adds the system projection + specular sheen the
// custom style can't fake.
//
// This needs LIVE focus (real device or simulator): static `RenderPreview` snapshots
// never engage the tvOS focus engine, and `hoverEffectPhaseOverride(.active)` — the
// documented force-active API — is explicitly `unavailable` on tvOS. To run it on the
// Apple TV, flip `posterFocusSpike` in `ParallaxApp` and Run.

/// Stand-in poster: gradient + big glyph so specular/parallax have structure to act on,
/// clipped like `MediaTile` (the corner-mismatch under test happens at this clip).
private struct SpikeTile: View {
    let hue: Color

    var body: some View {
        LinearGradient(
            colors: [hue, .black],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "film")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 220, height: 330)
        .clipShape(.rect(cornerRadius: Radius.tile))
    }
}

/// All three variants on one screen so the remote can walk focus between them and the
/// differences read side by side. The June 2026 device A/B picked C over the old custom
/// uniform-lift style ("C is much better"), and the components adopted it — so row A
/// (the shipped composition) must now match row C (the raw spec); row B stays as the
/// control showing the system-mask corner mismatch the shaped content shape fixes.
struct PosterFocusSpikeScreen: View {
    private let hues: [Color] = [.indigo, .teal, .brown]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s40) {
            section("A · shipped (tvShelfItem + tvPosterHighlight)") { hue in
                Button {} label: {
                    SpikeTile(hue: hue)
                        .tvPosterHighlight(cornerRadius: Radius.tile)
                }
                .tvShelfItem()
            }
            section("B · borderless bare (rejected control)") { hue in
                Button {} label: {
                    SpikeTile(hue: hue)
                }
                .buttonStyle(.borderless)
            }
            section("C · borderless + shaped highlight (candidate)") { hue in
                Button {} label: {
                    SpikeTile(hue: hue)
                        .hoverEffect(.highlight)
                        .contentShape(.hoverEffect, .rect(cornerRadius: Radius.tile))
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }

    @ViewBuilder
    private func section(
        _ title: String,
        @ViewBuilder tile: @escaping (Color) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondaryLabel)
            HStack(spacing: Space.s30) {
                ForEach(Array(hues.enumerated()), id: \.offset) { _, hue in
                    tile(hue)
                }
            }
        }
    }
}

// MARK: - Lockup text-nudge spike

// Second spike (July 2026): the native `.borderless` lockup promises "the button's title
// and any nearby section titles automatically move out of the way of the button's image
// as it scales up on focus" (Apple, "Creating a tvOS media catalog app in SwiftUI").
// The shipped `MediaTile` shape — VStack{ thumbnail + metadata row } as the button label —
// gets NO text movement on device (search episode tiles: the lifted still lands on the
// title). Hypothesis: pre-wrapping in the VStack hides the text from the style's
// avoidance layout, and passing the thumbnail and text as SIBLINGS in the label closure
// restores it. Row A = shipped control; B = docs pattern (sibling Text); C = sibling
// metadata CONTAINER (what MediaTile's two-line row needs). Like the poster spike above,
// this needs live focus — flip `lockupTextSpike` in `ParallaxApp` and Run on the TV.

/// One knob for the still and its caption block — they must stay the same width or the
/// text-avoidance geometry under test is skewed.
private let spikeCellWidth: CGFloat = 400
/// One source for the title in rows B and C, so the A/B/C comparison is same-content.
private let spikeEpisodeTitle = "第13.5話「お惚気チャカポコ」"

/// 16:9 stand-in for a search episode still, sized near the 3-up search grid cell.
private struct SpikeStill: View {
    let hue: Color

    var body: some View {
        LinearGradient(colors: [hue, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "play.tv")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: spikeCellWidth, height: 225)
            .clipShape(.rect(cornerRadius: Radius.tile))
    }
}

/// The two-line metadata block `MediaTile` hangs under a search episode still.
private struct SpikeMetadata: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spikeEpisodeTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.label)
                .lineLimit(1)
            HStack(spacing: Space.s8) {
                Text("S0 · E4 · デュラララ!!").lineLimit(1)
                Spacer(minLength: 0)
                Text("23 min").lineLimit(1).layoutPriority(1)
            }
            .font(.caption2)
            .foregroundStyle(Color.secondaryLabel)
        }
        .frame(width: spikeCellWidth, alignment: .leading)
    }
}

struct LockupTextSpikeScreen: View {
    private let hues: [Color] = [.indigo, .teal]

    var body: some View {
        // s40 rows: the focused tile's lift needs the same clearance the production grids
        // adopted, or up/down swipes geometry-search against an overlapping lifted frame.
        VStack(alignment: .leading, spacing: Space.s40) {
            section("A · contained VStack label (control, text stays static)") { hue in
                Button {} label: {
                    VStack(alignment: .leading, spacing: MediaTile.metadataGap) {
                        SpikeStill(hue: hue)
                            .tvPosterHighlight(cornerRadius: Radius.tile)
                        SpikeMetadata()
                    }
                }
                .tvPosterButton()
            }
            section("B · siblings + Text (docs lockup pattern)") { hue in
                Button {} label: {
                    SpikeStill(hue: hue)
                        .tvPosterHighlight(cornerRadius: Radius.tile)
                    Text(spikeEpisodeTitle)
                        .font(.subheadline.weight(.medium))
                }
                .tvPosterButton()
            }
            section("C · siblings + metadata container (shipped as MediaTile.lockup())") { hue in
                Button {} label: {
                    SpikeStill(hue: hue)
                        .tvPosterHighlight(cornerRadius: Radius.tile)
                    SpikeMetadata()
                }
                .tvPosterButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }

    @ViewBuilder
    private func section(
        _ title: String,
        @ViewBuilder tile: @escaping (Color) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondaryLabel)
            HStack(alignment: .top, spacing: Space.s40) {
                ForEach(Array(hues.enumerated()), id: \.offset) { _, hue in
                    tile(hue)
                }
            }
        }
    }
}

#Preview("Poster focus spike") {
    PosterFocusSpikeScreen()
}

#Preview("Lockup text spike") {
    LockupTextSpikeScreen()
}

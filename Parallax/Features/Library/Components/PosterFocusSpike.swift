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

#Preview("Poster focus spike") {
    PosterFocusSpikeScreen()
}

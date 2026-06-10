import SwiftUI

/// Icon-only circular glass action button used over the hero backdrop (Favorite,
/// Watched, …) — a native Liquid Glass circle on every platform (one body, system-owned
/// metrics, focus, and press feedback). The active state is a glyph-level cue: callers
/// pass the filled symbol variant.
/// - tvOS: bare `.glass` — the system owns the focus treatment (translucent at rest,
///   platter + lift on focus); forcing glyph color or scheme breaks the inversion.
/// - iOS: same style pinned `.dark` so the glass resolves the dark frosted variant over
///   bright photography (near-identical fill to the old custom `heroGlass` frost,
///   pixel-measured), with a pinned white glyph.
struct CircleGlassButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        // `Button { action() }` (not `action:` directly) — see PrimaryPlayButton: the
        // stored closure trips the preview thunk's isolation inference.
        Button {
            action()
        } label: {
            // `.headline` — the SAME font as the Play pill's label, not a custom glyph
            // size: native buttons derive their padding/height from the label font, so
            // sharing the font is what makes the disc and the pill come out the same
            // height (a 28pt custom glyph rendered a visibly shorter disc).
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                #if !os(tvOS)
                .foregroundStyle(.white)
                #endif
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        #if !os(tvOS)
        .controlSize(.extraLarge)
        #endif
        // Optical overshoot: a circle whose diameter exactly equals the pill's height
        // READS smaller next to its flat edges (same reason type "O" overshoots "H") —
        // pixel-measured equal in the parity preview, yet it still looked shorter. A
        // scale transform is the only lever: the `.glass` style derives the disc size
        // from the label font and ignores label padding entirely (measured: ±0px).
        .scaleEffect(1.05)
        #if !os(tvOS)
        // Native glass follows `colorScheme`; pin dark so light mode / bright artwork
        // doesn't resolve the near-white variant (measured rgb(222,219,255) unpinned vs
        // rgb(25,21,62) pinned — the latter matches the old heroGlass frost).
        .environment(\.colorScheme, .dark)
        #endif
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

#Preview("Action row parity") {
    ZStack {
        LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        VStack(spacing: Space.s12) {
            // The shipped components — must pixel-match the raw-native spec row below.
            HStack(spacing: Space.s12) {
                PrimaryPlayButton(title: "Play", fillWidth: false) {}
                CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") {}
                CircleGlassButton(systemImage: "checkmark.circle", accessibilityLabel: "Watched") {}
            }
            // Detail-page composition — the row inside a `GlassEffectContainer` (the
            // container draws member glass in its own layer; any glyph-vs-disc offset
            // that appears ONLY here is the container interacting with the buttons).
            GlassEffectContainer(spacing: Space.s8) {
                HStack(spacing: Space.s12) {
                    PrimaryPlayButton(title: "Play", fillWidth: false) {}
                    CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") {}
                    CircleGlassButton(systemImage: "checkmark.circle", accessibilityLabel: "Watched") {}
                }
            }
            // The approved iOS spec, built from raw native parts (user-approved June
            // 2026; the components above adopted it — on tvOS they stay bare `.glass`
            // so this row only matches row 1 on iOS).
            HStack(spacing: Space.s12) {
                Button {} label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.playPillFill)
                // controlSize is unavailable on tvOS; there the style's own metrics rule.
                #if !os(tvOS)
                .controlSize(.extraLarge)
                #endif
                Button {} label: {
                    Image(systemName: "heart")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #if !os(tvOS)
                .controlSize(.extraLarge)
                #endif
                .scaleEffect(1.05)
                // Same trick as the custom chrome: pin dark so the glass resolves the
                // dark frosted variant over bright artwork instead of near-white.
                .environment(\.colorScheme, .dark)
                Button {} label: {
                    Image(systemName: "checkmark.circle")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #if !os(tvOS)
                .controlSize(.extraLarge)
                #endif
                .scaleEffect(1.05)
                .environment(\.colorScheme, .dark)
            }
        }
    }
}

#Preview("CircleGlassButton · bright artwork") {
    ZStack {
        LinearGradient(
            colors: [Color(red: 0.95, green: 0.92, blue: 0.85),
                     Color(red: 0.78, green: 0.82, blue: 0.90)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        HStack(spacing: Space.s12) {
            CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") {}
            CircleGlassButton(systemImage: "heart.fill", accessibilityLabel: "Favorite") {}
        }
    }
    .preferredColorScheme(.light)
}

import SwiftUI

/// Circular glass control (Close, ±10s skip, play/pause, PiP, AirPlay frame) —
/// ONE material for the whole transport: the shared over-video glass. Play/pause
/// used to be a solid-white "primary" platter (the tvOS focused-platter look
/// ported to touch); it read as a heavier, alien material next to its glass
/// siblings and was retired (user-flagged) — size alone carries its emphasis,
/// like the TV app's transport. White line glyphs are stroked; play/pause pass
/// an already-filled SF Symbol. `.glassEffect` paints a material but adds no
/// hit region, so the whole disc gets an explicit `contentShape`.
struct PlayerRoundButton: View {
    let systemImage: String
    let size: CGFloat
    var iconScale: CGFloat = 0.46
    /// Vertical optical correction as a fraction of the glyph point size (negative = up).
    /// SwiftUI centers the symbol CANVAS (it honors e.g. play.fill's baked +5% rightward
    /// optical margin — pixel-measured), but `gobackward.10`/`goforward.10` ship with NO
    /// compensation for the arrowhead protruding above the ring, so canvas-centering
    /// parks the visible ring ~5% of the font size low inside the disc. Callers pass
    /// `skipGlyphYOffset` on those glyphs to center the RING; symmetric glyphs need nothing.
    var glyphOpticalYOffset: CGFloat = 0
    /// The 10-skip ring correction every `gobackward.10`/`goforward.10` call site passes —
    /// one constant so the value can be retired in one place if Apple ever bakes the
    /// compensation into the symbols (see `glyphOpticalYOffset`).
    static let skipGlyphYOffset: CGFloat = -0.05
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVFocusReader { focused in
                // tvOS HIG focus contract: focused = opaque white disc + ink glyph,
                // FADED over an always-mounted glass base (a structural swap fired
                // the GlassEffectContainer's matchedGeometry morph and snapped with
                // no crossfade). Rest = the shared over-video recipe; `off` while
                // focused so the material (edge rim + outward shadow) vanishes
                // under the platter.
                icon(color: focused ? .playerInk : .white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(.white.opacity(0.97)).opacity(focused ? 1 : 0))
                    .playerGlassSurface(in: Circle(), off: focused)
                    .animation(.tvFocusChrome, value: focused)
                    .contentShape(Circle())
            }
        }
        .tvChipButton()
        #if !os(tvOS)
        // Same tint-only pointer treatment as the chips (HIG: no scale in tight rows).
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(accessibilityLabel)
    }

    private func icon(color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size * iconScale, weight: .semibold))
            .foregroundStyle(color)
            .offset(y: size * iconScale * glyphOpticalYOffset)
            // Play/pause glyph swaps arrive from engine beats, not taps — after a
            // drag-scrub the resume's .playing often lands mid HUD fade-in, and a
            // bare string swap cut the glyph to "pause" at full opacity while the
            // disc was still animating in. The symbol Replace keeps the swap inside
            // the motion (and animates normal play/pause toggles too). The scoped
            // animation is keyed on the glyph name, so static-glyph buttons (skip,
            // Close, PiP) never get a transaction out of it.
            .contentTransition(.symbolEffect(.replace))
            .animation(.default, value: systemImage)
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.blue, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        HStack(spacing: 24) {
            PlayerRoundButton(systemImage: "gobackward.10", size: 80, iconScale: 0.48,
                              accessibilityLabel: "Back 10") {}
            PlayerRoundButton(systemImage: "pause.fill", size: 120, iconScale: 0.42,
                              accessibilityLabel: "Pause") {}
            PlayerRoundButton(systemImage: "goforward.10", size: 80, iconScale: 0.48,
                              accessibilityLabel: "Forward 10") {}
        }
    }
    .environment(\.colorScheme, .dark)
}

// Diagnostic: the EXACT composition of the iPad transport row — buttons inside a
// `GlassEffectContainer` (PlayerControlsView wraps them; the bare preview above does
// not). The container renders member glass in its own layer, so any glyph-vs-disc
// misalignment that only reproduces here is the container's doing.
// `play.fill` on purpose: its triangle measures ~5% of the font size RIGHT of the disc
// center — that's Apple's optical margin baked into the symbol canvas (a bbox-centered
// triangle reads left-heavy). Don't "fix" it.
#Preview("Transport in container") {
    ZStack {
        LinearGradient(colors: [.blue, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        GlassEffectContainer(spacing: Space.s8) {
            HStack(spacing: 76) {
                PlayerRoundButton(systemImage: "gobackward.10", size: 96, iconScale: 0.52,
                                  glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                  accessibilityLabel: "Back 10") {}
                PlayerRoundButton(systemImage: "play.fill", size: 140, iconScale: 0.46,
                                  accessibilityLabel: "Play") {}
                PlayerRoundButton(systemImage: "goforward.10", size: 96, iconScale: 0.52,
                                  glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                  accessibilityLabel: "Forward 10") {}
            }
        }
    }
    .environment(\.colorScheme, .dark)
}

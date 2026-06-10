import SwiftUI

/// Circular glass control (Close, ±10s skip, PiP, AirPlay frame). The `primary`
/// variant is the solid-white play/pause disc with dark glyph. White line glyphs are
/// stroked; play/pause pass an already-filled SF Symbol. `.glassEffect` paints a
/// material but adds no hit region, so the whole disc gets an explicit `contentShape`.
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
    var primary: Bool = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVFocusReader { focused in
                Group {
                    if primary {
                        icon(color: .playerInk)
                            .frame(width: size, height: size)
                            .background(Circle().fill(.white.opacity(0.97)))
                            .shadow(color: .black.opacity(0.32), radius: 8 * (size / 120), y: 4)
                    } else {
                        // tvOS HIG focus contract: focused = opaque white disc + ink glyph,
                        // FADED over an always-mounted glass base (a structural swap fired
                        // the GlassEffectContainer's matchedGeometry morph and snapped with
                        // no crossfade). Rest = `.clear` glass + a dim layer, per Apple's
                        // media-controls guidance: the regular variant's dark frost (the
                        // player pins `.dark`) is so heavy over video it read as a flat
                        // tinted disc, not glass. Clear lets the footage refract through;
                        // the black 0.3 keeps the glyph legible.
                        // `.identity` while focused: the mounted glass's material (edge
                        // rim + outward shadow) vanishes under the platter.
                        icon(color: focused ? .playerInk : .white)
                            .frame(width: size, height: size)
                            .background(Circle().fill(.white.opacity(0.97)).opacity(focused ? 1 : 0))
                            .glassEffect(focused ? .identity : .clear.interactive(), in: Circle())
                            .background(.black.opacity(focused ? 0 : 0.3), in: Circle())
                            .overlay(
                                Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1)
                                    .opacity(focused ? 0 : 1)
                            )
                            .animation(.tvFocusChrome, value: focused)
                    }
                }
                .contentShape(Circle())
            }
        }
        .tvChipButton()
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
                              primary: true, accessibilityLabel: "Pause") {}
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
            HStack(spacing: 68) {
                PlayerRoundButton(systemImage: "gobackward.10", size: 80, iconScale: 0.48,
                                  glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                  accessibilityLabel: "Back 10") {}
                PlayerRoundButton(systemImage: "play.fill", size: 120, iconScale: 0.42,
                                  primary: true, accessibilityLabel: "Play") {}
                PlayerRoundButton(systemImage: "goforward.10", size: 80, iconScale: 0.48,
                                  glyphOpticalYOffset: PlayerRoundButton.skipGlyphYOffset,
                                  accessibilityLabel: "Forward 10") {}
            }
        }
    }
    .environment(\.colorScheme, .dark)
}

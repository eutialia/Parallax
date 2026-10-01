import SwiftUI

/// Circular glass control (Close, rotate, episode skip, play/pause) —
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
    /// Dim + non-interactive when false (a prev/next-episode button at a series
    /// boundary). On tvOS a disabled button is also unfocusable, so the focus engine
    /// skips it instead of stranding on a dead target.
    var isEnabled: Bool = true
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
                    .background(Circle().fill(.white).opacity(focused ? 1 : 0))
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
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func icon(color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size * iconScale, weight: .semibold))
            .foregroundStyle(color)
            // Play/pause glyph swaps arrive from engine beats, not taps — after a
            // drag-scrub the resume's .playing often lands mid HUD fade-in, and a
            // bare string swap cut the glyph to "pause" at full opacity while the
            // disc was still animating in. The symbol Replace keeps the swap inside
            // the motion (and animates normal play/pause toggles too). The scoped
            // animation is keyed on the glyph name, so static-glyph buttons (episode
            // skip, Close) never get a transaction out of it.
            .contentTransition(.symbolEffect(.replace))
            .animation(.default, value: systemImage)
    }
}

// Episode transport: prev · play · next at iPad scale inside the `GlassEffectContainer`
// PlayerControlsView wraps them in, with `next` disabled (a series finale / movie) to
// check the 0.4 dim and the `.end.fill` glyph weight (0.42 iconScale) against the 0.46
// play disc. `play.fill` measures ~5% of the font size RIGHT of the disc center: Apple's
// optical margin baked into the symbol canvas. Don't "fix" it.
#Preview("Episode transport") {
    ZStack {
        LinearGradient(colors: [.blue, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        GlassEffectContainer(spacing: Space.s8) {
            HStack(spacing: 76) {
                PlayerRoundButton(systemImage: "backward.end.fill", size: 96, iconScale: 0.42,
                                  accessibilityLabel: "Previous episode") {}
                PlayerRoundButton(systemImage: "pause.fill", size: 140, iconScale: 0.46,
                                  accessibilityLabel: "Pause") {}
                PlayerRoundButton(systemImage: "forward.end.fill", size: 96, iconScale: 0.42,
                                  isEnabled: false, accessibilityLabel: "Next episode") {}
            }
        }
    }
    .environment(\.colorScheme, .dark)
}

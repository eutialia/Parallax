import SwiftUI

/// Pill control for Audio / Subtitles / Speed / Chapters. Liquid Glass off-state with
/// a white hairline; solid-white on-state with dark ink label (the active/menu-open
/// look). All sizes scale via `metrics`. `tvChipButton()` supplies the tvOS focus lift
/// (no system platter) and `.plain` on iOS.
struct PlayerGlassChip: View {
    let systemImage: String
    let label: String
    var sub: String? = nil
    var isActive: Bool = false
    let metrics: PlayerMetrics
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVFocusReader { focused in
                content(focused: focused)
            }
        }
        .tvChipButton()
        .accessibilityLabel(accessibilityLabel)
    }

    /// tvOS shows the active chip on a frosted tinted-glass base (the platter is focus's);
    /// iOS has no focus engine, so active IS the platter and the tint base never applies.
    /// A computed property (not a `let false` in `content`) so the iOS compiler doesn't
    /// constant-fold the border ternary into a "will never be executed" warning.
    private var usesActiveTintBase: Bool {
        #if os(tvOS)
        isActive
        #else
        false
        #endif
    }

    @ViewBuilder
    private func content(focused: Bool) -> some View {
        // tvOS HIG focus contract: the FOCUSED chip owns the solid-white-platter + ink
        // look, so the active state must not reuse it (a white "active" chip reads as
        // focused and made selection ambiguous on Apple TV). Active-but-unfocused gets a
        // brighter tinted glass instead. iOS has no focus engine, so active keeps the
        // solid look there — white means "this menu is open", nothing competes with it.
        #if os(tvOS)
        let platter = focused
        #else
        let platter = isActive
        #endif
        let activeTint = usesActiveTintBase
        let fg: Color = platter ? .playerInk : .white
        // The platter is a fading layer OVER an always-mounted glass base, never an
        // `if platter` branch: branching unmounted the glassEffect from the chip row's
        // `GlassEffectContainer` on every focus change, firing its matchedGeometry morph
        // against neighbours, and snapped the chrome with no crossfade. Only the
        // active/rest glass split stays structural — that flips on click, not focus.
        let inner = HStack(spacing: metrics.chipGap) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.chipIconSize, weight: .semibold))
            Text(label)
                .font(.system(size: metrics.chipFontSize, weight: .semibold))
                .lineLimit(1)
            if let sub {
                Text(sub)
                    .font(.system(size: metrics.chipFontSize, weight: .semibold))
                    .foregroundStyle(fg.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(fg)
        .frame(height: metrics.chipHeight)
        .padding(.horizontal, metrics.chipPadX)
        .background(Capsule().fill(.white.opacity(0.93)).opacity(platter ? 1 : 0))

        // While the platter shows, the still-mounted glass flips to `.identity` so its
        // material (edge rim + outward shadow, which opaque white can't cover) vanishes.
        Group {
            if activeTint {
                inner.glassEffect(
                    platter ? .identity : .regular.tint(.white.opacity(0.22)).interactive(),
                    in: Capsule()
                )
            } else {
                // `.clear` + dim layer (Apple's media-controls guidance): regular's dark
                // frost read as a flat tinted pill over video. The material ramp is now
                // rest = clear glass · active = frosted tinted glass · focused = platter.
                inner.glassEffect(platter ? .identity : .clear.interactive(), in: Capsule())
                    .background(.black.opacity(platter ? 0 : 0.3), in: Capsule())
            }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(platter ? 0.5 : activeTint ? 0.45 : 0.20), lineWidth: 1))
        .contentShape(Capsule())
        .animation(.tvFocusChrome, value: platter)
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        HStack(spacing: 14) {
            PlayerGlassChip(systemImage: "waveform", label: "English", sub: "5.1",
                            metrics: .tv, accessibilityLabel: "Audio") {}
            PlayerGlassChip(systemImage: "captions.bubble", label: "Subtitles", sub: "Off",
                            metrics: .tv, accessibilityLabel: "Subtitles") {}
            PlayerGlassChip(systemImage: "timer", label: "1.0×",
                            isActive: true, metrics: .tv, accessibilityLabel: "Speed") {}
        }
    }
    .frame(width: 820, height: 220)   // fixed canvas so the .tv-scale chips don't truncate
    .environment(\.colorScheme, .dark)
}

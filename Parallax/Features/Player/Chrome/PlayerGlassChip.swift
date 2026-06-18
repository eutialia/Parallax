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
    /// The chip has vacated its spot for the inline track panel (iOS): content goes
    /// transparent AND the glass flips to `.identity`, which removes the material at
    /// the source — a bare `.opacity(0)` leaves the capsule visible whenever a
    /// `GlassEffectContainer` is rendering member glass in its own layer (the tvOS
    /// focus-ghost class of bug; the chip row's container is gone, but identity
    /// keeps this correct regardless of future containment).
    var isVacated: Bool = false
    let metrics: PlayerMetrics
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        #if os(tvOS)
        // tvOS: glass INSIDE the button — the platter follows focus, which only the
        // reader inside the label can see.
        Button(action: action) {
            TVFocusReader { focused in
                chrome(chipLabel(platter: focused), platter: focused)
            }
        }
        .tvChipButton()
        .accessibilityLabel(accessibilityLabel)
        #else
        // iOS: glass OUTSIDE the button (the split pill's architecture). Bisect
        // renders proved `.interactive()` glass inside a Button paints an armed,
        // brighter standing sheen — the "super glass" chips next to the subtle
        // pill. No focus engine here, so the platter is purely `isActive`, which
        // is known without the reader.
        chrome(
            Button(action: action) {
                chipLabel(platter: isActive)
                    .contentShape(Capsule())
            }
            .tvChipButton(),
            platter: isActive
        )
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .accessibilityLabel(accessibilityLabel)
        #endif
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

    // tvOS HIG focus contract: the FOCUSED chip owns the solid-white-platter + ink
    // look, so the active state must not reuse it (a white "active" chip reads as
    // focused and made selection ambiguous on Apple TV). Active-but-unfocused gets a
    // brighter tinted glass instead. iOS has no focus engine, so active keeps the
    // solid look there — white means "this menu is open", nothing competes with it.
    //
    // The platter is a fading layer OVER an always-mounted glass base, never an
    // `if platter` branch: a structural swap fires any enclosing glass container's
    // matchedGeometry morph and snaps with no crossfade. Only the active/rest glass
    // split stays structural — that flips on click, not focus.
    private func chipLabel(platter: Bool) -> some View {
        let fg: Color = platter ? .playerInk : .white
        return HStack(spacing: metrics.chipGap) {
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
    }

    /// The capsule's material: glass + dim + hairline, with the platter/vacated
    /// states flipping the glass to `.identity` so its material (edge rim + outward
    /// shadow, which opaque white can't cover) vanishes.
    @ViewBuilder
    private func chrome(_ content: some View, platter: Bool) -> some View {
        let activeTint = usesActiveTintBase
        let glassOff = platter || isVacated
        Group {
            if activeTint {
                content.glassEffect(
                    glassOff ? .identity : .regular.tint(.white.opacity(0.22)).interactive(),
                    in: Capsule()
                )
            } else {
                // The shared over-video recipe, minus its hairline (the chip's rim is
                // stateful, below). The material ramp is rest = clear glass · active =
                // frosted tinted glass · focused = platter.
                content.playerGlassSurface(in: Capsule(), off: glassOff, hairline: nil)
            }
        }
        .overlay {
            Capsule().strokeBorder(
                .white.opacity(isVacated ? 0 : platter ? 0.5 : activeTint ? 0.45 : 0.20), lineWidth: 1)
        }
        .opacity(isVacated ? 0 : 1)
        // The vacated chip is invisible but its Button isn't gone: without these the
        // tap survives by ZStack-ordering luck alone, and VoiceOver (which ignores
        // hit order) can still focus and re-fire the hidden chip under its panel.
        .allowsHitTesting(!isVacated)
        .accessibilityHidden(isVacated)
        .contentShape(Capsule())
        .animation(.tvFocusChrome, value: platter)
    }
}

// The real iPhone bottom row at its compact `.phone` scale, over a dark wash so the
// glass reads — checks the chip set doesn't crowd horizontally and the pill height is
// the intended ~36pt (see `PlayerMetrics.phoneChip*`). `.fixedLayout` pins the canvas to
// an iPhone-landscape-width slice so it renders without a portrait device frame.
#Preview("iPhone chip row", traits: .fixedLayout(width: 852, height: 150)) {
    ZStack {
        LinearGradient(colors: [.black.opacity(0.2), .black], startPoint: .top, endPoint: .bottom)
        HStack(spacing: PlayerMetrics.phoneChipRowGap) {
            PlayerGlassChip(systemImage: "waveform", label: "Japanese", sub: "5.1",
                            metrics: .phone, accessibilityLabel: "Audio") {}
            PlayerGlassChip(systemImage: "captions.bubble", label: "Chinese (Simplified)",
                            metrics: .phone, accessibilityLabel: "Subtitles") {}
            PlayerGlassChip(systemImage: "timer", label: "1×",
                            metrics: .phone, accessibilityLabel: "Speed") {}
            PlayerGlassChip(systemImage: "list.bullet", label: "Chapters",
                            metrics: .phone, accessibilityLabel: "Chapters") {}
            PlayerGlassChip(systemImage: "ladybug", label: "Debug",
                            metrics: .phone, accessibilityLabel: "Debug") {}
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlayerMetrics.phonePadX)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, PlayerMetrics.phoneChipRowBottom)
    }
    .environment(\.colorScheme, .dark)
}

#Preview("Track chips · tv", traits: .fixedLayout(width: 820, height: 220)) {
    ZStack {
        LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
        HStack(spacing: 14) {
            PlayerGlassChip(systemImage: "waveform", label: "English", sub: "5.1",
                            metrics: .tv, accessibilityLabel: "Audio") {}
            PlayerGlassChip(systemImage: "captions.bubble", label: "Subtitles", sub: "Off",
                            metrics: .tv, accessibilityLabel: "Subtitles") {}
            PlayerGlassChip(systemImage: "timer", label: "1.0×",
                            isActive: true, metrics: .tv, accessibilityLabel: "Speed") {}
        }
    }
    .environment(\.colorScheme, .dark)
}

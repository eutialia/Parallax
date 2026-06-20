import SwiftUI

/// Icon-only circular action button over hero/detail artwork (Favorite, Watched, …).
/// FLAT, matching the 4K/HDR/CC badges: a `heroGlass` fill + hairline + white glyph — Liquid
/// Glass is reserved for the player + system bars. On tvOS the disc inverts to the HIG white
/// platter + ink glyph on focus (with the `tvChipButton()` lift); iOS never focuses. The active
/// state is a glyph-level cue — callers pass the filled symbol variant.
struct CircleGlassButton: View {
    let systemImage: String
    let accessibilityLabel: String
    /// Drops the resting disc fill + hairline so the control reads as a bare glyph until focus,
    /// then lights up to the SAME white focus platter as the standard variant. For lightweight
    /// pager affordances (the tvOS hero carousel's "next" chevron) that shouldn't sit as a solid
    /// peer of Favorite at rest. Keep it tvOS-only at the call site: iOS never focuses, so a bare
    /// glyph would simply never gain its platter.
    var bareUntilFocused: Bool = false
    let action: () -> Void

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // `Button { action() }` (not `action:` directly) — the stored closure trips the preview
        // thunk's isolation inference (see PrimaryPlayButton).
        Button {
            action()
        } label: {
            TVFocusReader { focused in
                let d = ActionRow.controlHeight(idiom)
                // `.headline` — the SAME font as the Play pill's label, so the row's optical
                // weight matches; the disc/pill heights are matched explicitly via `ActionRow`.
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(focused ? Color.playerInk : .white)
                    .frame(width: d, height: d)
                    .flatControlFill(
                        focused: focused,
                        rest: bareUntilFocused ? .clear : .heroGlass,
                        hairline: bareUntilFocused ? nil : .heroGlassBorder,
                        in: Circle()
                    )
            }
        }
        // Owns the button style (tvOS lift / `.plain` on iOS) — never pair an inner `.buttonStyle`.
        .tvChipButton()
        #if !os(tvOS)
        // Optical overshoot: a circle reads smaller than the flat-edged pill at equal height.
        .scaleEffect(1.05)
        #endif
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

#Preview("Flat action row · over artwork") {
    ZStack {
        LinearGradient(
            colors: [Color(red: 0.93, green: 0.86, blue: 0.72),
                     Color(red: 0.30, green: 0.42, blue: 0.58)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        VStack(spacing: Space.s30) {
            HStack(spacing: ActionRow.gap) {
                PrimaryPlayButton(title: "Play", fillWidth: false) {}
                CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") {}
                CircleGlassButton(systemImage: "checkmark.circle", accessibilityLabel: "Watched") {}
            }
            // Active states — filled-glyph on-state.
            HStack(spacing: ActionRow.gap) {
                CircleGlassButton(systemImage: "heart.fill", accessibilityLabel: "Favorited") {}
                CircleGlassButton(systemImage: "checkmark.circle.fill", accessibilityLabel: "Watched") {}
            }
        }
        .environment(\.appIdiom, .regular)
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
        HStack(spacing: ActionRow.gap) {
            CircleGlassButton(systemImage: "heart", accessibilityLabel: "Favorite") {}
            CircleGlassButton(systemImage: "heart.fill", accessibilityLabel: "Favorite") {}
        }
        .environment(\.appIdiom, .compact)
    }
    .preferredColorScheme(.light)
}

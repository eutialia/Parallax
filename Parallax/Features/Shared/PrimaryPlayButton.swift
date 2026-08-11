import SwiftUI

/// Primary action over hero/detail artwork. iPhone/iPad: WHITE-TINTED INTERACTIVE LIQUID GLASS
/// (owner directive 2026-08-10, amending the 2026-07-14 "flat pill" rule for the hero action row:
/// the flat white pill had no border, so it vanished into white artwork — the glass rim is the
/// visibility mechanism). Still ALWAYS white + ink label in BOTH themes: the pill rides artwork,
/// a dark-pinned region, so it must not flip with the app theme (the old espresso-by-day face
/// read as a hole in the hero). tvOS keeps the flat white treatment — its focus platter + the
/// `tvChipButton()` lift/shadow are device-tuned and carry visibility on their own.
/// Label patterns: "Play", "Resume · 1h 02m left", "Resume S3 E1".
struct PrimaryPlayButton: View {
    let title: String
    var systemImage: String = "play.fill"
    /// Full-width pill (the default, used as a standalone row) vs an intrinsic-width pill (used
    /// inline in the hero's action row, beside the circle buttons).
    var fillWidth: Bool = true
    /// When set, an invisible wider label reserves width so the pill stays one size as the copy
    /// changes ("Play" → "Resume S9 E9") and doesn't reflow.
    var layoutReserveTitle: String? = nil
    let action: () -> Void

    @Environment(\.appIdiom) private var idiom
    @Environment(\.heroActionRowFocusScope) private var heroActionRowFocusScope

    var body: some View {
        // `Button { action() }`, not `Button(action: action)`: passing the stored closure directly
        // trips Xcode's preview thunk (`__designTimeSelection` isolation inference), killing #Preview.
        Button {
            action()
        } label: {
            TVFocusReader { focused in
                content(focused: focused)
            }
        }
        // Owns the button style (tvOS lift / `.plain` on iOS) — never pair an inner `.buttonStyle`.
        .tvChipButton()
        // Inside a hero action row (scope non-nil), Play is where DEFAULT focus lands when the
        // tvOS engine resolves into the row on screen open — the geometric fallback picks by row
        // width, which made a movie detail (three controls) open on Favorite. See `HeroForeground`.
        .tvPrefersDefaultFocus(in: heroActionRowFocusScope)
    }

    @ViewBuilder
    private func content(focused: Bool) -> some View {
        // Theme-FIXED white/ink, like the player vocabulary — no two-faced tokens, no colorScheme
        // read. Rest and tvOS-focused fills are both white; focus reads through lift + shadow.
        labelStack
            .font(.headline)
            .foregroundStyle(Color.playerInk)
            .padding(.horizontal, Space.s22)
            .frame(height: ActionRow.controlHeight(idiom))
            .frame(maxWidth: fillWidth ? .infinity : nil)
            #if os(tvOS)
            .flatControlFill(focused: focused, rest: .white, in: Capsule())
            #else
            // Glass ON THE LABEL, not a glass buttonStyle: `tvChipButton()` keeps `.plain`, so
            // the geometry tokens (control height, s22 inset, capsule) stay the single source —
            // a glass style would wrap its own insets around them and break pill/circle parity.
            // `.interactive()` gives the press response a plain style otherwise loses.
            .glassEffect(.regular.tint(.white).interactive(), in: Capsule())
            // Pin the glass to its dark variant: `glassEffect` resolves light/dark from the
            // environment, and this row rides dark-pinned artwork — unpinned, the row flips
            // with the app theme (the exact drift the theme-fixed rule forbids). Same recipe
            // as LibraryCard's tinted glass.
            .environment(\.colorScheme, .dark)
            #endif
    }

    /// The label, optionally reserving the widest copy's width behind the live title so the pill
    /// never resizes as Play↔Resume swaps.
    @ViewBuilder
    private var labelStack: some View {
        if let layoutReserveTitle {
            ZStack {
                Label(layoutReserveTitle, systemImage: systemImage)
                    .opacity(0)
                    .accessibilityHidden(true)
                Label(title, systemImage: systemImage)
            }
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

#Preview("PrimaryPlayButton") {
    VStack(spacing: Space.s22) {
        PrimaryPlayButton(title: "Play") {}
        PrimaryPlayButton(title: "Resume · 1h 02m left") {}
        PrimaryPlayButton(title: "Play", fillWidth: false, layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle) {}
        PrimaryPlayButton(
            title: "Resume S3 E1",
            fillWidth: false,
            layoutReserveTitle: ItemPlayButtonLabel.layoutReserveTitle
        ) {}
    }
    .padding(Space.s40)
    .background(Color.background)
    .environment(\.appIdiom, .regular)
}

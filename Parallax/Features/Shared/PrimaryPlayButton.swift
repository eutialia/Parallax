import SwiftUI

/// Primary action over hero/detail artwork — a FLAT solid pill (Liquid Glass is reserved for the
/// player + system bars). ALWAYS a white pill + ink label, in BOTH themes (owner directive
/// 2026-07-14): the pill rides artwork — a dark-pinned region like `heroGlass` — so it must not
/// flip with the app theme (the old espresso-by-day face read as a hole in the hero). On tvOS
/// focus keeps the same white; the `tvChipButton()` lift + focus shadow carry the state, exactly
/// as dark mode always behaved. Label patterns: "Play", "Resume · 1h 02m left", "Resume S3 E1".
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
            .flatControlFill(focused: focused, rest: .white, in: Capsule())
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

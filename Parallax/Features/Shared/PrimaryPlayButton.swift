import SwiftUI

/// Primary action over hero/detail artwork — a native Liquid Glass pill on every
/// platform (one body, system-owned behavior).
/// - tvOS: bare `.glass` — the system owns rest/focus/platter/label colors; tinting or
///   forcing a label color breaks the focus inversion (white label on white platter).
/// - iOS: `.glassProminent` tinted the frozen espresso `playPillFill` + pure white
///   label — pixel-matched to the approved row-3 prototype in "Action row parity".
/// Label patterns: "Play", "Resume · 1h 02m left", "Resume S3 E1".
struct PrimaryPlayButton: View {
    let title: String
    var systemImage: String = "play.fill"
    /// Full-width pill (the default, used as a standalone row) vs an intrinsic-width
    /// pill (used inline in the hero's action row, beside the glass buttons).
    var fillWidth: Bool = true
    /// When set, an invisible wider label reserves width so the pill stays one size as
    /// the copy changes ("Play" → "Resume S9 E9") and doesn't reflow.
    var layoutReserveTitle: String? = nil
    let action: () -> Void

    var body: some View {
        // `Button { action() }`, not `Button(action: action)`: passing the stored
        // closure directly trips Xcode's preview thunk (`__designTimeSelection` infers
        // conflicting `() -> Void` vs `@MainActor () -> Void`), killing #Preview here.
        Button {
            action()
        } label: {
            playLabel
        }
        #if os(tvOS)
        .buttonStyle(.glass)
        #else
        .buttonStyle(.glassProminent)
        .tint(Color.playPillFill)
        // controlSize is unavailable on tvOS; .extraLarge lands ~50pt at .headline,
        // the closest native metric to the previous 46pt custom pill.
        .controlSize(.extraLarge)
        // Pin dark so light mode / bright artwork doesn't resolve the near-white glass
        // variant (measured rgb(222,219,255) unpinned vs rgb(25,21,62) pinned —
        // CircleGlassButton applies the same fix for the same reason).
        .environment(\.colorScheme, .dark)
        #endif
    }

    @ViewBuilder
    private var playLabel: some View {
        let label = sizedLabel(title)
            .frame(maxWidth: fillWidth ? .infinity : nil)

        if let layoutReserveTitle {
            ZStack {
                sizedLabel(layoutReserveTitle)
                    .opacity(0)
                    .accessibilityHidden(true)
                label
            }
        } else {
            label
        }
    }

    /// Bare label: the native styles supply their own padding, height, and platter
    /// metrics — hand-sizing fought the system geometry (and is ignored anyway).
    private func sizedLabel(_ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            #if !os(tvOS)
            // Pure white (not the warm buttonLabel): legible on the frozen espresso
            // tint in both schemes. On tvOS the system picks the label color so the
            // focused platter can invert it.
            .foregroundStyle(.white)
            #endif
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
}

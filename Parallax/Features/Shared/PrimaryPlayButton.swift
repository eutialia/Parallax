import SwiftUI

/// Solid, high-contrast primary action — the #1 "feel" lever. Monochrome:
/// buttonFill (white in dark / espresso in light), buttonLabel content, full pill.
/// Label patterns: "Play", "Resume · 1h 02m left", "Resume S3 E1".
struct PrimaryPlayButton: View {
    let title: String
    var systemImage: String = "play.fill"
    /// Full-width pill (the default, used as a standalone row) vs an intrinsic-width
    /// pill (used inline in the hero's action row, beside the glass buttons).
    var fillWidth: Bool = true
    let action: () -> Void

    /// Pill height scales with Dynamic Type (relative to the `.headline` label) so the
    /// label never clips at larger text sizes.
    @ScaledMetric(relativeTo: .headline) private var playHeight: CGFloat = 46

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(height: playHeight)
                .padding(.horizontal, Space.s22)
                .frame(maxWidth: fillWidth ? .infinity : nil)
        }
        .buttonStyle(PrimaryPlayButtonStyle())
    }
}

private struct PrimaryPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.buttonLabel)
            .background(Color.buttonFill, in: Capsule())
            .shadow(color: .black.opacity(0.24), radius: 10, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("PrimaryPlayButton") {
    VStack(spacing: Space.s22) {
        PrimaryPlayButton(title: "Play") {}
        PrimaryPlayButton(title: "Resume · 1h 02m left") {}
    }
    .padding(Space.s40)
    .background(Color.background)
}

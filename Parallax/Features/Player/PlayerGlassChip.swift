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
            content
        }
        .tvChipButton()
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        let fg: Color = isActive ? .playerInk : .white
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

        Group {
            if isActive {
                inner.background(.white.opacity(0.93), in: Capsule())
            } else {
                inner.glassEffect(.regular, in: Capsule())
            }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(isActive ? 0.5 : 0.20), lineWidth: 1))
        .contentShape(Capsule())
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

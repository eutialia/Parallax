import SwiftUI

/// A single glass pill holding the AirPlay + PiP icon segments joined by a hairline
/// divider (iPad top-right). Either segment is omitted if its capability is absent; if
/// only one is present the pill is a single segment. iPhone does not use this — it has a
/// standalone AirPlay button (top) and a PiP button (bottom).
struct PlayerSplitPill: View {
    let metrics: PlayerMetrics
    let airPlayAvailable: Bool
    let pipAvailable: Bool
    let onPiP: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if airPlayAvailable {
                AirPlayRouteButton()
                    .frame(width: metrics.splitPillSegment, height: metrics.splitPillHeight)
            }
            if airPlayAvailable && pipAvailable {
                Rectangle().fill(.white.opacity(0.24))
                    .frame(width: 1, height: metrics.splitPillDivider)
            }
            if pipAvailable {
                Button(action: onPiP) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: metrics.splitPillIcon, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: metrics.splitPillSegment, height: metrics.splitPillHeight)
                        .contentShape(Rectangle())
                }
                .tvChipButton()
                .accessibilityLabel("Picture in Picture")
            }
        }
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 1))
        .clipShape(Capsule())
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.teal, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        PlayerSplitPill(metrics: .tv, airPlayAvailable: true, pipAvailable: true) {}
    }
    .frame(width: 400, height: 220)
    .environment(\.colorScheme, .dark)
}

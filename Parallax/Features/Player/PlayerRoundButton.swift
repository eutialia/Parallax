import SwiftUI

/// Circular glass control (Close, ±10s skip, PiP, AirPlay frame). The `primary`
/// variant is the solid-white play/pause disc with dark glyph. White line glyphs are
/// stroked; play/pause pass an already-filled SF Symbol. `.glassEffect` paints a
/// material but adds no hit region, so the whole disc gets an explicit `contentShape`.
struct PlayerRoundButton: View {
    let systemImage: String
    let size: CGFloat
    var iconScale: CGFloat = 0.46
    var primary: Bool = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if primary {
                    icon(color: .playerInk)
                        .frame(width: size, height: size)
                        .background(Circle().fill(.white.opacity(0.97)))
                        .shadow(color: .black.opacity(0.32), radius: 8 * (size / 120), y: 4)
                } else {
                    icon(color: .white)
                        .frame(width: size, height: size)
                        .glassEffect(.regular, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1))
                }
            }
            .contentShape(Circle())
        }
        .tvChipButton()
        .accessibilityLabel(accessibilityLabel)
    }

    private func icon(color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size * iconScale, weight: .semibold))
            .foregroundStyle(color)
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.blue, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        HStack(spacing: 24) {
            PlayerRoundButton(systemImage: "gobackward.10", size: 80, iconScale: 0.48,
                              accessibilityLabel: "Back 10") {}
            PlayerRoundButton(systemImage: "pause.fill", size: 120, iconScale: 0.42,
                              primary: true, accessibilityLabel: "Pause") {}
            PlayerRoundButton(systemImage: "goforward.10", size: 80, iconScale: 0.48,
                              accessibilityLabel: "Forward 10") {}
        }
    }
    .environment(\.colorScheme, .dark)
}

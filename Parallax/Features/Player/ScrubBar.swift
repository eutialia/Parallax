import SwiftUI

/// The minimal overlay shown during a swipe scrub on the clean floor: timeline +
/// current/target time only, no transport or chips. `progress` is the preview head
/// (0...1); `durationSeconds` drives the time read-outs. Non-interactive — the
/// remote adapter drives it.
struct ScrubBar: View {
    let progress: Double
    let durationSeconds: Double

    private var clamped: Double { min(max(progress, 0), 1) }
    private var shownSeconds: Double { clamped * durationSeconds }
    private var remaining: Double { max(0, durationSeconds - shownSeconds) }

    var body: some View {
        HStack(spacing: 14) {
            Text(formatPlaybackTime(shownSeconds))
                .font(Font.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 104, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white)
                        .frame(width: geo.size.width * clamped)
                    Circle().fill(.white)
                        .frame(width: 22, height: 22)
                        .offset(x: geo.size.width * clamped - 11)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                }
            }
            .frame(height: 8)

            Text(remaining > 0 ? "-\(formatPlaybackTime(remaining))" : formatPlaybackTime(durationSeconds))
                .font(Font.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ScrubBar(progress: 0.42, durationSeconds: 5400)
    }
}

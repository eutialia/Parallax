import SwiftUI

/// The player's loading state, rendered AS the video surface (not a blocking
/// overlay): a liquid-filled glass orb that sloshes the Jellyfin accent gradient
/// while the source buffers or an audio track re-resolves. Per the design, this is
/// the ONE sanctioned moment of vibrant color in the otherwise-monochrome player —
/// the chrome around it stays live and interactive.
///
/// Recreates `loading.css`'s orb: a glass vial clipping a purple→blue liquid whose
/// surface is two slowly counter-rotating blobs, with cyan bubbles rising and a soft
/// accent glow pulsing behind. Indeterminate and endless — the caller swaps it out
/// when playback resumes. Honors Reduce Motion (static filled orb + glow, no shimmer).
///
/// App target only: pure SwiftUI, no platform conditionals.
struct LoaderOrb: View {
    var label: String = "Loading"
    var sublabel: String? = nil
    /// Diameter of the glass vial. The design renders it at ~1.7× in the player.
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The accent gradient — the sanctioned vibrant color. Kept literal here (not a
    // DesignToken) because the tokens are deliberately monochrome; this is the lone
    // exception the design calls out.
    private static let purple = Color(.sRGB, red: 0.667, green: 0.361, blue: 0.765) // #AA5CC3
    private static let indigo = Color(.sRGB, red: 0.431, green: 0.420, blue: 0.839) // #6E6BD6
    private static let cyan   = Color(.sRGB, red: 0.000, green: 0.643, blue: 0.863) // #00A4DC
    private static let bubble = Color(.sRGB, red: 0.247, green: 0.765, blue: 0.925) // #3FC3EC
    private static let glow   = Color(.sRGB, red: 0.557, green: 0.388, blue: 0.839) // #8E63D6

    private static let liquid = LinearGradient(
        colors: [purple, indigo, cyan],
        startPoint: .topLeading, endPoint: .bottomTrailing // ≈150°
    )

    var body: some View {
        VStack(spacing: 22) {
            orb
            if !label.isEmpty {
                VStack(spacing: 3) {
                    shimmerLabel
                    if let sublabel {
                        Text(sublabel)
                            .font(.system(size: size * 0.15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }
                .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sublabel.map { "\(label), \($0)" } ?? label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Orb

    private var orb: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                glowHalo(t)
                vial(t)
            }
            .frame(width: size, height: size)
        }
    }

    /// Soft accent glow that pulses behind the orb (radial purple→cyan→clear).
    private func glowHalo(_ t: TimeInterval) -> some View {
        // 3.2s pulse: scale 0.9→1.08, opacity 0.6→1.
        let pulse = reduceMotion ? 0.5 : (sin(t / 3.2 * 2 * .pi) + 1) / 2 // 0…1
        let scale = 0.9 + 0.18 * pulse
        let opacity = 0.6 + 0.4 * pulse
        return Circle()
            .fill(
                RadialGradient(
                    colors: [Self.glow.opacity(0.6), Self.cyan.opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: size * 0.92
                )
            )
            .frame(width: size * 1.84, height: size * 1.84)
            .scaleEffect(scale)
            .opacity(opacity)
            .blur(radius: size * 0.06)
    }

    /// The glass vial clipping the sloshing liquid + rising bubbles.
    private func vial(_ t: TimeInterval) -> some View {
        ZStack {
            // Glass backing with inner depth.
            Circle()
                .fill(.white.opacity(0.05).shadow(.inner(color: .black.opacity(0.28), radius: size * 0.12, y: size * 0.12)))

            // Liquid: two counter-rotating blobs whose rounded edges undulate the surface.
            ZStack {
                liquidBlob(t, period: 5.2, reversed: false, opacity: 1.0)
                liquidBlob(t, period: 8.0, reversed: true, opacity: 0.55)
                bubbles(t)
            }
            .clipShape(Circle())
        }
        .overlay(
            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Self.glow.opacity(0.35), radius: size * 0.16, y: size * 0.10)
    }

    /// One liquid blob: a rounded square larger than the vial, rotating slowly so its
    /// corners cross the waterline and ripple it. Filled with the accent gradient.
    private func liquidBlob(_ t: TimeInterval, period: Double, reversed: Bool, opacity: Double) -> some View {
        let turns = reduceMotion ? 0 : (t.truncatingRemainder(dividingBy: period) / period)
        let angle = Angle.degrees(turns * 360 * (reversed ? -1 : 1))
        return RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
            .fill(Self.liquid)
            .frame(width: size * 1.66, height: size * 1.66)
            .rotationEffect(angle)
            // Push the blob down so ~58% of the vial is filled, the waterline sitting
            // just above center; rotation makes the corners slosh it.
            .offset(y: size * 0.72)
            .opacity(opacity)
    }

    /// Three cyan bubbles rising and fading, staggered — effervescence.
    private func bubbles(_ t: TimeInterval) -> some View {
        let specs: [(x: CGFloat, d: CGFloat, period: Double, delay: Double)] = [
            (-0.10, 0.10, 2.8, 0.0),
            ( 0.05, 0.086, 3.6, 0.9),
            ( 0.19, 0.069, 3.1, 1.7),
        ]
        return ZStack {
            ForEach(0..<specs.count, id: \.self) { i in
                let s = specs[i]
                let p = reduceMotion ? 0.4 : ((t + s.delay).truncatingRemainder(dividingBy: s.period) / s.period)
                // Opacity: 0 → .9 (at 20%) → .7 → 0; rise 0 → -0.59*size.
                let opacity = bubbleOpacity(p)
                Circle()
                    .fill(Self.bubble)
                    .frame(width: size * s.d, height: size * s.d)
                    .offset(x: size * s.x, y: size * (0.40 - 0.59 * p))
                    .opacity(opacity)
            }
        }
    }

    private func bubbleOpacity(_ p: Double) -> Double {
        switch p {
        case ..<0.2:  return (p / 0.2) * 0.9
        case ..<0.8:  return 0.9 - (p - 0.2) / 0.6 * 0.2
        default:      return 0.7 * (1 - (p - 0.8) / 0.2)
        }
    }

    // MARK: - Label

    private var shimmerLabel: some View {
        let base = Text(label)
            .font(.system(size: size * 0.2, weight: .bold))
            .foregroundStyle(.white)
        return Group {
            if reduceMotion {
                base
            } else {
                base.overlay {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = (t.truncatingRemainder(dividingBy: 2.6) / 2.6) // 0…1
                        GeometryReader { geo in
                            let w = geo.size.width
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.85), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: w * 0.6)
                            .offset(x: -w * 0.8 + (w * 1.6) * phase)
                            .blendMode(.plusLighter)
                        }
                    }
                    .mask(base)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

#Preview("LoaderOrb") {
    ZStack {
        LinearGradient(colors: [Color(.sRGB, red: 0.10, green: 0.07, blue: 0.16), .black],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        Color.black.opacity(0.45).ignoresSafeArea()
        LoaderOrb(label: "Switching audio", sublabel: "English · 5.1 · AC3", size: 100)
    }
}

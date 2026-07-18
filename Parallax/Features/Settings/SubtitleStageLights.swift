import SwiftUI
import ParallaxPlayback

/// The floating subtitle "lights" — a translucent overlay that fades in over EVERYTHING while the
/// Subtitles menu is open (the menu itself is a normal pushed screen). The whole view dims, a soft
/// spotlight pool lifts only the sample cue, and the cue is drawn at its EXACT on-screen playback
/// position (same `PlayerMetrics.forSurface` geometry + `SubtitleCueText` renderer as the real
/// `SubtitleOverlayView`), so it's a true 1:1 of playback. Non-interactive — the dimmed menu stays
/// fully tappable underneath; the spotlight + cue track the live style as the user adjusts it.
struct SubtitleStageLights: View {
    let style: SubtitleStyle
    /// The spotlit sample cue. Not a lorem-ipsum pangram — the preview is a tiny lit stage, so the
    /// line earns its moment. It also narrates itself: the lights fade in *slowly*, and a setting is
    /// something you nudge incrementally until it suddenly clicks — slowly, then all at once. Short
    /// enough to stay one line at any size, so the spotlight always centers cleanly.
    var sample: String = "Slowly, then all at once."

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Identical geometry to playback.
            let metrics = PlayerMetrics.forSurface(size)
            let cueSize = metrics.subtitleFontSize * style.fontScale
            let bottomPad = metrics.subtitleBottom + style.verticalOffsetRatio * size.height
            let cueCenterY = size.height - bottomPad - cueSize * 0.6
            let spot = UnitPoint(x: 0.5, y: max(0.12, min(0.94, cueCenterY / size.height)))
            let pool = min(size.width, size.height) * 0.55

            ZStack {
                // The dim is a spotlight: LEAST dimmed at the cue (the menu shows through brightest
                // there), deepening outward — so the surround recedes and the cue reads as the subject.
                RadialGradient(
                    colors: [.black.opacity(0.10), .black.opacity(0.40), .black.opacity(0.58)],
                    center: spot, startRadius: 0, endRadius: pool * 1.5
                )
                // A soft beam of light on the cue.
                RadialGradient(
                    colors: [.white.opacity(0.10), .clear],
                    center: spot, startRadius: 0, endRadius: pool
                )
                .blendMode(.plusLighter)
                // Floor pool just under the cue, to seat it.
                Ellipse()
                    .fill(.white.opacity(0.10))
                    .frame(width: size.width * 0.5, height: cueSize * 1.5)
                    .position(x: size.width / 2, y: min(size.height - 8, cueCenterY + cueSize * 0.85))
                    .blur(radius: 26)
                    .blendMode(.plusLighter)

                // The real-position cue — same renderer + geometry as the player overlay.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SubtitleCueText(sample, fontSize: cueSize, style: style)
                        .padding(.horizontal, metrics.subtitleInsetX)
                        .padding(.bottom, bottomPad)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .animation(.smooth(duration: 0.28), value: style)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // never block the menu underneath
    }
}

#if DEBUG
/// Lights over a mock menu, so the dim + spotlight + cue read against real content.
#Preview("Subtitle stage lights — over menu", traits: .fixedLayout(width: 393, height: 852)) {
    ZStack {
        BackgroundField.style
        SubtitleControlsList(style: .standard, onChange: { _ in })
            .frame(maxWidth: 540)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 60)
        SubtitleStageLights(style: .standard.with {
            $0.foreground = .init(red: 1.0, green: 0.93, blue: 0.30)
            $0.fontScale = 1.25
        })
    }
}
#endif

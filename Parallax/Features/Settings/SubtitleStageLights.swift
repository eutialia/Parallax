import ParallaxPlayback
import ParallaxSubtitles
import SwiftUI

/// The floating subtitle "lights" — a translucent overlay that fades in over EVERYTHING while the
/// Subtitles menu is open (the menu itself is a normal pushed screen). The whole view dims, a soft
/// spotlight pool lifts only the sample cue — and the cue is NOT a mock-up: `SubtitleLivePreview`
/// renders it through the real libass pipeline with the exact override mapping playback pushes, so
/// what the lights show is what plays (size, backing, and the cue's distance from the video's
/// bottom edge — the stage bottom stands in for it). Non-interactive — the dimmed menu stays fully
/// tappable underneath; the cue re-renders live as the user adjusts the style.
struct SubtitleStageLights: View {
    let style: SubtitleStyle

    @State private var preview = SubtitleLivePreview()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let cue = cueLayout(in: size)
            let spot = UnitPoint(x: 0.5, y: max(0.12, min(0.94, cue.center.y / size.height)))
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
                    .frame(width: size.width * 0.5, height: max(24, cue.size.height * 0.8))
                    .position(x: size.width / 2, y: min(size.height - 8, cue.center.y + cue.size.height * 0.75))
                    .blur(radius: 26)
                    .blendMode(.plusLighter)

                // The real cue — the renderer's own bitmap, placed at its true
                // distance from the (virtual) video bottom edge.
                if let frame = preview.frame, let image = frame.image {
                    Image(decorative: image, scale: preview.pointScale)
                        .position(cue.center)
                }
            }
            .animation(.smooth(duration: 0.28), value: style)
            .onChange(of: style, initial: true) {
                preview.update(style: style, stageSize: size, displayScale: displayScale)
            }
            .onChange(of: size) {
                preview.update(style: style, stageSize: size, displayScale: displayScale)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // never block the menu underneath
    }

    /// Where the rendered frame sits on the stage: the same transform the player
    /// overlay applies (pixels → points, then the user lift), with the stage's
    /// bottom edge standing in for the virtual video's bottom edge.
    private func cueLayout(in size: CGSize) -> (center: CGPoint, size: CGSize) {
        guard let frame = preview.frame, frame.canvasSize.height > 0, preview.pointScale > 0 else {
            // Nothing rendered yet — aim the spotlight where cues land.
            return (CGPoint(x: size.width / 2, y: size.height * 0.82), CGSize(width: 0, height: 24))
        }
        let scale = preview.pointScale
        let cueSize = CGSize(
            width: frame.imageRect.width / scale,
            height: frame.imageRect.height / scale
        )
        let bottomGap = (frame.canvasSize.height - frame.imageRect.maxY) / scale + preview.lift
        let center = CGPoint(
            x: size.width / 2 + (frame.imageRect.midX - frame.canvasSize.width / 2) / scale,
            y: size.height - bottomGap - cueSize.height / 2
        )
        return (center, cueSize)
    }
}

#if DEBUG
/// Lights over a mock menu, so the dim + spotlight + cue read against real content.
/// The cue itself renders asynchronously through the live pipeline — give the
/// preview a beat before judging it.
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

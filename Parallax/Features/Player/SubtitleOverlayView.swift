import SwiftUI
import CoreMedia
import ParallaxPlayback

/// Draws client-rendered subtitle cues over the video surface, synced to the engine
/// clock (`PlaybackEngine.currentTime`, so it works for AVKit and VLC alike).
///
/// Used whenever `PlayerViewModel.activeSubtitleCues` is non-empty:
/// - Transcode: the correctly-timed WebVTT sidecar instead of the in-manifest HLS
///   WebVTT, whose `X-TIMESTAMP-MAP` drifts on fMP4 segments (jellyfin/jellyfin#16647).
/// - Direct-play external subs: VLC's simple text renderer can't shape sidecar VTT on
///   iOS (HarfBuzz "Runs count 0"), so we fetch + render them here instead of slaving
///   them to the engine.
///
/// Embedded subs (rendered by the engine itself — AVKit legible / VLC libass) leave
/// `activeSubtitleCues` empty, so this overlay draws nothing for them; those renderers
/// are pointed at the same `SubtitleStyle.standard` look from inside their engines.
struct SubtitleOverlayView: View {
    let vm: PlayerViewModel

    @State private var text: String?
    /// The video surface size, captured via `onGeometryChange` instead of a
    /// `GeometryReader` (which greedily expands and re-runs its closure every frame). The
    /// cue scale/inset/bottom all derive from `PlayerMetrics.forSurface(size)`; the first
    /// cue only appears once playback is live, by which point the size is already latched.
    @State private var surfaceSize: CGSize = .zero

    var body: some View {
        let metrics = PlayerMetrics.forSurface(surfaceSize)
        VStack {
            Spacer(minLength: 0)
            if let text {
                SubtitleCueText(text, fontSize: metrics.subtitleFontSize)
                    .padding(.horizontal, metrics.subtitleInsetX)
                    .padding(.bottom, metrics.subtitleBottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { surfaceSize = $0 }
        // Opt into full-bleed like the video host: PlayerView no longer applies a
        // blanket .ignoresSafeArea(), so without this the cues would float up by the
        // bottom safe-area inset instead of sitting just above the home indicator.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task { await drive() }
    }

    /// Polls the engine clock ~15×/s and shows whichever cue(s) contain "now".
    /// 0.5s playback-state beats are far too coarse for sub-second cues, so we
    /// read `engine.currentTime` directly rather than going through the state stream.
    private func drive() async {
        while !Task.isCancelled {
            text = currentCueText()
            try? await Task.sleep(for: .milliseconds(66))
        }
    }

    private func currentCueText() -> String? {
        let cues = vm.activeSubtitleCues
        // `.invalid` is VLC's "clock not ready" signal (buffering/seek); skip so a transient
        // unknown time doesn't flash the 0:00 cue. AVKit always reports a valid time (0 at the
        // start), so a genuine 0:00 cue still shows.
        guard !cues.isEmpty, let clock = vm.engine?.currentTime, clock.isValid else { return nil }
        // Apply the manual nudge: shift the match clock BACK by the delay so a positive
        // delay makes each cue fire that much later — the escape hatch for the transcode
        // seek desync where the engine clock runs ahead of the frames.
        let now = CMTimeSubtract(clock, CMTime(value: CMTimeValue(vm.clientSubtitleDelayMs), timescale: 1000))
        let active = cues.filter {
            CMTimeCompare(now, $0.start) >= 0 && CMTimeCompare(now, $0.end) < 0
        }
        guard !active.isEmpty else { return nil }
        return active.map(\.text).joined(separator: "\n")
    }
}

/// One subtitle cue in the canonical `SubtitleStyle`: boxless — a dimmed-white fill
/// inside a black glyph border, over a soft shadow for separation on light content.
/// SwiftUI cannot stroke glyphs (no outline API; `TextRenderer` exposes runs, not
/// paths), so the border is the classic ring of offset copies drawn behind the fill:
/// layout-neutral (offsets don't grow the footprint) and crisp at the 1–3pt widths
/// cue text uses.
private struct SubtitleCueText: View {
    let text: String
    let fontSize: CGFloat

    init(_ text: String, fontSize: CGFloat) {
        self.text = text
        self.fontSize = fontSize
    }

    /// Unit vectors for the 8-direction border ring.
    private static let ring: [CGSize] = (0..<8).map {
        let angle = Double($0) * .pi / 4
        return CGSize(width: cos(angle), height: sin(angle))
    }

    private static let style = SubtitleStyle.standard
    private static let fillColor = Color(style.foreground)
    private static let borderColor = Color(style.outline)
    private static let shadowColor = Color.black.opacity(style.shadowOpacity)

    var body: some View {
        let style = Self.style
        let borderWidth = max(1, fontSize * style.outlineWidthRatio)
        ZStack {
            ForEach(Self.ring.indices, id: \.self) { i in
                cue.foregroundStyle(Self.borderColor)
                    .offset(x: Self.ring[i].width * borderWidth,
                            y: Self.ring[i].height * borderWidth)
            }
            cue.foregroundStyle(Self.fillColor)
        }
        // Flatten before shadowing: applied straight to the ZStack, SwiftUI would
        // shadow each of the 9 copies individually.
        .compositingGroup()
        .shadow(color: Self.shadowColor,
                radius: fontSize * style.shadowRadiusRatio,
                x: 0, y: fontSize * style.shadowYOffsetRatio)
    }

    private var cue: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .multilineTextAlignment(.center)
    }
}

private extension Color {
    init(_ rgba: SubtitleStyle.RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

/// Worst-case legibility check: each device class's cue size over light, busy
/// content — the case the old black pill existed for. The border + shadow must
/// keep every size readable against the white band.
#Preview("Cue sizes on light content", traits: .fixedLayout(width: 900, height: 620)) {
    ZStack {
        LinearGradient(colors: [.white, Color(white: 0.85), .yellow.opacity(0.6), Color(white: 0.3)],
                       startPoint: .top, endPoint: .bottom)
        VStack(spacing: 44) {
            SubtitleCueText("Phone 20 — The quick brown fox\njumps over the lazy dog.", fontSize: 20)
            SubtitleCueText("iPad ~22 — The quick brown fox\njumps over the lazy dog.", fontSize: 22)
            SubtitleCueText("tvOS 46 — The quick brown fox\njumps over the lazy dog.", fontSize: 46)
        }
    }
    .ignoresSafeArea()
}

import SwiftUI
import UIKit
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
    /// User subtitle appearance (size/color/font/background/position). Overlay-only —
    /// injected at the app root, inherited here through both the iOS player overlay
    /// host and the tvOS `fullScreenCover`.
    @Environment(SubtitlePreferences.self) private var subtitlePrefs

    @State private var text: String?
    /// The video surface size, captured via `onGeometryChange` instead of a
    /// `GeometryReader` (which greedily expands and re-runs its closure every frame). The
    /// cue scale/inset/bottom all derive from `PlayerMetrics.forSurface(size)`; the first
    /// cue only appears once playback is live, by which point the size is already latched.
    @State private var surfaceSize: CGSize = .zero

    var body: some View {
        let metrics = PlayerMetrics.forSurface(surfaceSize)
        let style = subtitlePrefs.style
        let size = metrics.subtitleFontSize * style.fontScale
        // Lift above the base bottom inset by the user's offset (fraction of surface height).
        let bottom = metrics.subtitleBottom + style.verticalOffsetRatio * surfaceSize.height
        VStack {
            Spacer(minLength: 0)
            if let text {
                SubtitleCueText(text, fontSize: size, style: style)
                    .padding(.horizontal, metrics.subtitleInsetX)
                    .padding(.bottom, bottom)
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
        // PROTECTED INVARIANT: matching absolute cue times against the engine clock
        // is only valid because out-of-buffer transcode seeks re-anchor a fresh
        // session instead of restarting ffmpeg in-stream (PlayerViewModel.seek(to:)).
        // A mid-session restart shifts the item's established timeline mapping under
        // these cues — the 2026-07-17 post-scrub desync. Don't add seek paths that
        // bypass that gate.
        guard !cues.isEmpty, let now = vm.engine?.currentTime, now.isValid else { return nil }
        let active = cues.filter {
            CMTimeCompare(now, $0.start) >= 0 && CMTimeCompare(now, $0.end) < 0
        }
        guard !active.isEmpty else { return nil }
        return active.map(\.text).joined(separator: "\n")
    }
}

/// One subtitle cue in the given `SubtitleStyle`. Two legibility backings, chosen by
/// `style.background`:
/// - `.outlineShadow` — boxless: a black glyph ring over a soft shadow. SwiftUI can't
///   stroke glyph paths (`TextRenderer` exposes runs, not outlines), so the ring is the
///   classic set of offset copies behind the fill — layout-neutral and crisp at cue widths.
/// - `.opaqueBox` — a solid panel behind the text, no ring or shadow (the box carries
///   its own contrast).
///
/// Internal (not `private`) so the Subtitle settings live preview renders the *real* cue,
/// not a lookalike.
struct SubtitleCueText: View {
    let text: String
    let fontSize: CGFloat
    let style: SubtitleStyle

    init(_ text: String, fontSize: CGFloat, style: SubtitleStyle) {
        self.text = text
        self.fontSize = fontSize
        self.style = style
    }

    /// Unit vectors for the 8-direction border ring.
    private static let ring: [CGSize] = (0..<8).map {
        let angle = Double($0) * .pi / 4
        return CGSize(width: cos(angle), height: sin(angle))
    }

    var body: some View {
        switch style.background {
        case .outlineShadow: outlined
        case .opaqueBox: boxed
        }
    }

    /// Boxless: a black glyph ring over a soft shadow.
    private var outlined: some View {
        // Resolve the font ONCE per render. `.serif` builds a UIFont-from-descriptor cascade, and the
        // ring draws 9 copies (8 offsets + fill) — recomputing it per copy was rebuilding that cascade
        // 9× every body tick on the live subtitle path.
        let font = style.fontDesign.cueFont(size: fontSize)
        let borderWidth = max(1, fontSize * style.outlineWidthRatio)
        return ZStack {
            ForEach(Self.ring.indices, id: \.self) { i in
                cueText(font).foregroundStyle(Color(style.outline))
                    .offset(x: Self.ring[i].width * borderWidth,
                            y: Self.ring[i].height * borderWidth)
            }
            cueText(font).foregroundStyle(Color(style.foreground))
        }
        // Flatten before shadowing: applied straight to the ZStack, SwiftUI would
        // shadow each of the 9 copies individually.
        .compositingGroup()
        .shadow(color: .black.opacity(style.shadowOpacity),
                radius: fontSize * style.shadowRadiusRatio,
                x: 0, y: fontSize * style.shadowYOffsetRatio)
    }

    /// Opaque panel behind the text — no ring, no shadow; the box supplies contrast.
    private var boxed: some View {
        cueText(style.fontDesign.cueFont(size: fontSize)).foregroundStyle(Color(style.foreground))
            .padding(.horizontal, fontSize * 0.40)
            .padding(.vertical, fontSize * 0.18)
            .background(.black, in: RoundedRectangle(cornerRadius: fontSize * 0.18, style: .continuous))
    }

    /// One copy of the cue text in an already-resolved `font` (so the serif cascade is built once by
    /// the caller and shared, not rebuilt per ring copy).
    private func cueText(_ font: Font) -> some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
    }
}

extension Color {
    init(_ rgba: SubtitleStyle.RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension SubtitleFontDesign {
    /// The cue font (always semibold). Sans/mono map straight to `Font.Design`. SERIF uses a font
    /// CASCADE — New York for Latin plus Hiragino Mincho (明朝, `HiraMinProN-W6`) as the CJK fallback —
    /// because SwiftUI's `.serif` design is New York (Latin only) and the system's CJK fallback for it
    /// is sans. iOS ships only a JAPANESE Mincho; it covers Han, so Chinese also renders serif (in JP
    /// glyph variants) — but there's no Chinese Songti or Korean Myeongjo, so Korean stays sans, and on
    /// tvOS (no Hiragino Mincho) the fallback is simply skipped → Latin serif, CJK sans. Proven by
    /// `SubtitleRenderTests.renderCJKFonts` / `renderCJKSerifCandidates`.
    func cueFont(size: CGFloat) -> Font {
        switch self {
        case .sansSerif:
            return .system(size: size, weight: .semibold, design: .default)
        case .monospaced:
            return .system(size: size, weight: .semibold, design: .monospaced)
        case .serif:
            let plain = UIFont.systemFont(ofSize: size, weight: .semibold)
            let base = plain.fontDescriptor.withDesign(.serif) ?? plain.fontDescriptor
            let cjk = UIFontDescriptor(fontAttributes: [.name: "HiraMinProN-W6"])
            let cascaded = base.addingAttributes([.cascadeList: [cjk]])
            return Font(UIFont(descriptor: cascaded, size: size))
        }
    }
}

/// Worst-case legibility check: cue sizes + both backings over light, busy content —
/// the case the old black pill existed for. The ring+shadow (and the opaque box) must
/// keep every size readable against the white band.
#Preview("Cue legibility — sizes & backings", traits: .fixedLayout(width: 900, height: 720)) {
    ZStack {
        LinearGradient(colors: [.white, Color(white: 0.85), .yellow.opacity(0.6), Color(white: 0.3)],
                       startPoint: .top, endPoint: .bottom)
        VStack(spacing: 32) {
            SubtitleCueText("Phone 20 — The quick brown fox\njumps over the lazy dog.", fontSize: 20, style: .standard)
            SubtitleCueText("tvOS 46 — The quick brown fox", fontSize: 46, style: .standard)
            SubtitleCueText("Opaque box — over busy content", fontSize: 30,
                            style: .standard.with { $0.background = .opaqueBox })
            SubtitleCueText("Yellow — readable on light", fontSize: 30,
                            style: .standard.with { $0.foreground = .init(red: 1, green: 0.93, blue: 0.30) })
        }
    }
    .ignoresSafeArea()
}

/// CJK-serif verification (subtitle-settings spec, first verify task): does SwiftUI's
/// `.serif` (New York, Latin) resolve to a SERIF CJK face (Songti / Mincho) via the
/// system cascade, or fall back to the SANS CJK face? Render this and compare the
/// System vs Serif rows for the 中文 / 日本語 / 한국어 samples by eye.
#Preview("Font design × CJK (serif check)", traits: .fixedLayout(width: 980, height: 760)) {
    let designs: [(String, SubtitleFontDesign)] = [("System (sans)", .sansSerif), ("Serif", .serif), ("Monospaced", .monospaced)]
    let samples = ["EN — Subtitle Aa Bb Gg 0123", "中文字幕测试 — 永遠", "日本語の字幕 — 永遠", "한국어 자막 — 영원"]
    return ZStack {
        Color(white: 0.16)
        VStack(spacing: 26) {
            ForEach(designs, id: \.0) { name, design in
                VStack(spacing: 6) {
                    Text(name).font(.caption).foregroundStyle(.white.opacity(0.55))
                    ForEach(samples, id: \.self) { sample in
                        SubtitleCueText(sample, fontSize: 30, style: .standard.with { $0.fontDesign = design })
                    }
                }
            }
        }
    }
    .ignoresSafeArea()
}

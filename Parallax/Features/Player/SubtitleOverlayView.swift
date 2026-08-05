import SwiftUI
import UIKit
import CoreMedia
import ParallaxPlayback
import ParallaxSubtitles

/// Draws the client-rendered subtitle bitmap over the video surface, synced to the
/// engine clock (`PlaybackEngine.currentTime`, so it works for AVKit and VLC alike).
///
/// Active whenever `PlayerViewModel.subtitleRenderer` is set — the libass-backed
/// `ParallaxSubtitles` engine loaded with a sidecar track:
/// - Transcode: the correctly-timed sidecar instead of the in-manifest HLS WebVTT,
///   whose `X-TIMESTAMP-MAP` drifts on fMP4 segments (jellyfin/jellyfin#16647).
/// - Direct-play external subs: VLC's simple text renderer can't shape sidecar text on
///   iOS (HarfBuzz "Runs count 0"), so we fetch + render them here instead of slaving
///   them to the engine.
///
/// Authored ASS/SSA renders with its creator styling and positioning (9-cell
/// alignment, `\pos` signs); SRT/VTT is converted to ASS events and takes the user's
/// `SubtitleStyle`. Embedded subs (rendered by the engine itself — AVKit legible /
/// VLC's internal libass) leave `subtitleRenderer` nil, so this overlay draws nothing
/// for them.
struct SubtitleOverlayView: View {
    let vm: PlayerViewModel
    /// User subtitle appearance + the authored-override toggle. Pushed into the
    /// renderer via `PlayerViewModel.applySubtitleAppearance` (format-aware policy
    /// lives there). Injected at the app root, inherited here through both the iOS
    /// player overlay host and the tvOS `fullScreenCover`.
    @Environment(SubtitlePreferences.self) private var subtitlePrefs
    @Environment(\.displayScale) private var displayScale

    @State private var frame: SubtitleFrame?
    /// Mirrors "the engine clock is readable" — while false (VLC buffering/seek) the
    /// last frame is HIDDEN, not discarded: the renderer's change-tracking doesn't
    /// know we blanked, so discarding would leave the cue lost until the next cue
    /// transition once the clock returns.
    @State private var clockValid = true
    /// The video surface size, captured via `onGeometryChange` instead of a
    /// `GeometryReader` (which greedily expands and re-runs its closure every frame).
    /// The render canvas derives from it; the first cue only appears once playback is
    /// live, by which point the size is already latched.
    @State private var surfaceSize: CGSize = .zero

    var body: some View {
        // The geometry anchor must be a view that ALWAYS lays out. Hanging
        // `onGeometryChange` off `SubtitleFrameView` itself deadlocks the pipeline:
        // frameless, its `if let` body collapses to nothing, the callback never
        // fires, `surfaceSize` stays .zero — and a zero canvas means the renderer
        // is never asked for a frame, so it stays frameless forever.
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { surfaceSize = $0 }
            .overlay(alignment: .topLeading) {
                SubtitleFrameView(
                    frame: clockValid ? frame : nil,
                    pointScale: displayScale,
                    canvasOrigin: videoRect.origin,
                    lift: lift
                )
            }
            // Opt into full-bleed like the video host: PlayerView no longer applies a
            // blanket .ignoresSafeArea(), so without this the canvas would be inset by
            // the safe area and every cue would land above the home indicator band.
            .ignoresSafeArea()
            .allowsHitTesting(false)
        // Keyed on the display scale: the drive loop runs off a captured copy of
        // self, so an environment change (external display, Stage Manager move)
        // must restart it to be observed — @Environment doesn't update inside a
        // long-running task.
        .task(id: displayScale) { await drive() }
        .onChange(of: subtitlePrefs.style) { pushAppearance() }
        .onChange(of: subtitlePrefs.overrideAuthoredStyles) { pushAppearance() }
    }

    /// The rect the video PICTURE actually occupies (aspect-fit of the native video
    /// dimensions into the surface, both engines render `.resizeAspect`). This — not
    /// the full surface — is the libass canvas: frame aspect == storage aspect keeps
    /// libass' derived pixel-aspect at 1 (no glyph stretch on letterboxed layouts),
    /// and authored `\pos` coordinates land on the picture features they were typeset
    /// against. Unknown video dimensions (SMB) fall back to the full surface.
    private var videoRect: CGRect {
        guard let video = vm.videoStorageSize, video.width > 0, video.height > 0,
              surfaceSize != .zero
        else { return CGRect(origin: .zero, size: surfaceSize) }
        let fit = min(surfaceSize.width / video.width, surfaceSize.height / video.height)
        let size = CGSize(width: video.width * fit, height: video.height * fit)
        return CGRect(
            x: (surfaceSize.width - size.width) / 2,
            y: (surfaceSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The user's bottom lift, honored only for converted SRT/VTT — their cues are
    /// synthesized bottom-center so raising the whole frame is safe. Authored ASS
    /// placements are exactly what the creator intended; never shift those.
    private var lift: CGFloat {
        guard let format = vm.sidecarSubtitleInfo?.format,
              format == .srt || format == .vtt else { return 0 }
        return subtitlePrefs.style.verticalOffsetRatio * surfaceSize.height
    }

    private func pushAppearance() {
        let style = subtitlePrefs.style
        vm.applySubtitleAppearance(
            converted: style.convertedRendererOverride(surface: surfaceSize, videoRect: videoRect),
            authored: style.rendererOverride(fontScale: style.fontScale),
            overrideAuthored: subtitlePrefs.overrideAuthoredStyles
        )
    }

    /// Polls the engine clock ~15×/s and renders whatever the track says belongs on
    /// screen "now". 0.5s playback-state beats are far too coarse for sub-second cues,
    /// so we read `engine.currentTime` directly rather than going through the state
    /// stream. `frame(at:)` returns nil when nothing changed, so idle ticks are cheap.
    private func drive() async {
        pushAppearance()
        // Canvas pushes are keyed on (renderer generation, video rect, scale) so the
        // actor hop happens only when one of them actually changed. Generation, not
        // object identity: a freed renderer's address can be reused by the next one.
        var pushedCanvas: CanvasKey?
        while !Task.isCancelled {
            guard let renderer = vm.subtitleRenderer else {
                frame = nil
                pushedCanvas = nil
                try? await Task.sleep(for: .milliseconds(66))
                continue
            }
            let rect = videoRect
            let key = CanvasKey(
                generation: vm.subtitleRendererGeneration, rect: rect, scale: displayScale
            )
            if key != pushedCanvas, rect.size != .zero {
                await renderer.setCanvas(
                    size: rect.size, scale: displayScale, storageSize: vm.videoStorageSize
                )
                pushedCanvas = key
                // The converted-track font mapping depends on the canvas height.
                pushAppearance()
            }
            // `.invalid` is VLC's "clock not ready" signal (buffering/seek); hide the
            // frame for that window so a transient unknown time doesn't flash a stale
            // cue. AVKit always reports a valid time (0 at the start), so a genuine
            // 0:00 cue still shows.
            // PROTECTED INVARIANT: matching absolute cue times against the engine clock
            // is only valid because out-of-buffer transcode seeks re-anchor a fresh
            // session instead of restarting ffmpeg in-stream (PlayerViewModel.seek(to:)).
            // A mid-session restart shifts the item's established timeline mapping under
            // these cues — the 2026-07-17 post-scrub desync. Don't add seek paths that
            // bypass that gate.
            if let now = vm.engine?.currentTime, now.isValid {
                clockValid = true
                if pushedCanvas != nil,
                   let fresh = await renderer.frame(at: CMTimeGetSeconds(now)) {
                    frame = fresh
                }
            } else {
                clockValid = false
            }
            try? await Task.sleep(for: .milliseconds(66))
        }
    }

    private struct CanvasKey: Equatable {
        let generation: Int
        let rect: CGRect
        let scale: CGFloat
    }
}

/// Pure placement of a rendered subtitle frame: `imageRect` is in canvas PIXELS with
/// a TOP-LEFT, y-down origin (libass' convention — which matches SwiftUI's), so the
/// transform is pixels → points via the display scale, then a shift by the canvas
/// origin (the video picture's rect inside the surface). Extracted from the overlay
/// so placement math is previewable/testable without a live renderer.
struct SubtitleFrameView: View {
    let frame: SubtitleFrame?
    /// Canvas pixels per point — the display scale the canvas was configured with.
    let pointScale: CGFloat
    /// Where the canvas (video picture rect) starts inside the surface, in points.
    var canvasOrigin: CGPoint = .zero
    /// Points to raise the whole frame (user lift, converted formats only).
    let lift: CGFloat

    var body: some View {
        if let frame, let image = frame.image, pointScale > 0 {
            Image(decorative: image, scale: pointScale)
                .offset(
                    x: canvasOrigin.x + frame.imageRect.minX / pointScale,
                    y: canvasOrigin.y + frame.imageRect.minY / pointScale - lift
                )
        }
    }
}

extension Color {
    init(_ rgba: SubtitleStyle.RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

/// Placement probe for `SubtitleFrameView`: a synthetic frame whose `imageRect` puts a
/// red block at the TOP-CENTER of a 390×260pt canvas (@3x pixels, libass' y-down
/// top-left origin). Rendered correctly, the block hugs the top edge, horizontally
/// centered — if it lands at the bottom or off-center, the pixel→point transform or
/// origin convention regressed. The green hairline marks the canvas midline.
#Preview("Frame placement — top-center probe", traits: .fixedLayout(width: 390, height: 260)) {
    let scale: CGFloat = 3
    let rect = CGRect(x: (390 * scale - 240) / 2, y: 24, width: 240, height: 90)
    let image: CGImage? = {
        let ctx = CGContext(
            data: nil, width: 240, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.setFillColor(CGColor(red: 0.9, green: 0.15, blue: 0.2, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: 240, height: 90))
        return ctx?.makeImage()
    }()
    return ZStack(alignment: .topLeading) {
        Color(white: 0.14)
        Rectangle().fill(.green).frame(width: 1).frame(maxWidth: .infinity, alignment: .center)
        SubtitleFrameView(
            frame: SubtitleFrame(
                image: image,
                imageRect: rect,
                canvasSize: CGSize(width: 390 * scale, height: 260 * scale)
            ),
            pointScale: scale,
            lift: 0
        )
    }
    .ignoresSafeArea()
}

/// Letterbox probe: the canvas is the video PICTURE rect (yellow outline, inset 40pt
/// top/bottom), not the surface — the same red top-center block must now hug the
/// yellow rect's top edge, 40pt below the surface top. If it sticks to the surface
/// top instead, the `canvasOrigin` shift regressed.
#Preview("Frame placement — letterboxed canvas probe", traits: .fixedLayout(width: 390, height: 260)) {
    let scale: CGFloat = 3
    let videoRect = CGRect(x: 0, y: 40, width: 390, height: 180)
    let rect = CGRect(x: (390 * scale - 240) / 2, y: 12, width: 240, height: 60)
    let image: CGImage? = {
        let ctx = CGContext(
            data: nil, width: 240, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.setFillColor(CGColor(red: 0.9, green: 0.15, blue: 0.2, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: 240, height: 60))
        return ctx?.makeImage()
    }()
    return ZStack(alignment: .topLeading) {
        Color(white: 0.14)
        Rectangle().strokeBorder(.yellow, lineWidth: 1)
            .frame(width: videoRect.width, height: videoRect.height)
            .offset(x: videoRect.minX, y: videoRect.minY)
        SubtitleFrameView(
            frame: SubtitleFrame(
                image: image,
                imageRect: rect,
                canvasSize: CGSize(width: videoRect.width * scale, height: videoRect.height * scale)
            ),
            pointScale: scale,
            canvasOrigin: videoRect.origin,
            lift: 0
        )
    }
    .ignoresSafeArea()
}


import CoreGraphics
import Foundation
import Observation
import ParallaxPlayback
import ParallaxSubtitles
import SwiftUI

/// Drives the settings preview through the REAL subtitle pipeline: the same
/// `SubtitleRenderer`, the same converted-script synthesis (CJK font planning
/// and size compensation included), and the same style-override mapping the
/// player overlay pushes (`convertedRendererOverride` — one function, so the
/// preview CANNOT drift from playback). The rendered bitmap is the preview.
///
/// The simulated session is a fullscreen landscape playback on this device —
/// the geometry the tuned cue sizes are authored against — scaled to fit the
/// stage's width so the wrapped cue can never overrun the stage.
@MainActor
@Observable
final class SubtitleLivePreview {

    /// The latest rendered cue frame; `imageRect` is in canvas pixels of the
    /// virtual video rect, exactly as playback receives it.
    private(set) var frame: SubtitleFrame?
    /// Canvas pixels per point for the frame above.
    private(set) var pointScale: CGFloat = 1
    /// The user's bottom lift at the time of render, in points — playback
    /// applies it in the overlay (not the renderer), so the preview must too.
    private(set) var lift: CGFloat = 0

    @ObservationIgnored private var renderer = SubtitleRenderer()
    @ObservationIgnored private var rendererFamily = SubtitleRenderer.standardFontFamily
    @ObservationIgnored private var loaded = false
    /// The latest requested render; a single worker drains it so a burst of
    /// updates (size sliders, live-resize geometry) coalesces to the newest
    /// request instead of rendering every intermediate one in order.
    @ObservationIgnored private var pending: (rect: CGRect, override: SubtitleStyleOverride, scale: CGFloat)?
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// The sample cue rides the whole conversion pipeline.
    private static let sampleSRT = """
    1
    00:00:01,000 --> 00:00:03,000
    Slowly, then all at once.

    """

    func update(style: SubtitleStyle, stageSize: CGSize, displayScale: CGFloat) {
        guard stageSize.width > 0, stageSize.height > 0, displayScale > 0 else { return }
        // A font-design change rebuilds the renderer around the new family —
        // the font plan is baked at load, exactly like playback's reinstall.
        let family = style.fontDesign.rendererFamily ?? SubtitleRenderer.standardFontFamily
        if family != rendererFamily {
            rendererFamily = family
            renderer = SubtitleRenderer(defaultFontFamily: family)
            loaded = false
        }
        // A fullscreen landscape session of this device, scaled to FIT the
        // stage's width: the converted mapping is canvas-height-invariant (the
        // cue renders at the same point size and the margin override pins the
        // same rest distance on any canvas), so shrinking the canvas changes
        // only the wrap width — which must not exceed the stage, or the bitmap
        // would run off both edges at large sizes.
        let landscape = CGSize(
            width: max(stageSize.width, stageSize.height),
            height: min(stageSize.width, stageSize.height)
        )
        let fit = stageSize.width / landscape.width
        let rect = CGRect(
            origin: .zero,
            size: CGSize(width: landscape.width * fit, height: landscape.height * fit)
        )
        let override = style.convertedRendererOverride(surface: stageSize, canvas: rect)

        pointScale = displayScale
        // The lift the player applies in landscape (ratio × landscape height).
        withAnimation(.smooth(duration: 0.28)) {
            lift = style.verticalOffsetRatio * landscape.height
        }

        // Last-edit-wins: park the request and let the single worker drain to
        // the newest one. The renderer is re-read per pass — a design change
        // swaps the instance between passes.
        pending = (rect, override, displayScale)
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while let request = pending {
                pending = nil
                let renderer = renderer
                if !loaded {
                    loaded = true
                    try? await renderer.load(Data(Self.sampleSRT.utf8), format: .srt)
                }
                await renderer.setCanvas(
                    size: request.rect.size, scale: request.scale, storageSize: nil
                )
                await renderer.setStyleOverride(request.override)
                // nil = nothing changed since the last render — keep what's shown.
                if let fresh = await renderer.frame(at: 2.0) {
                    withAnimation(.smooth(duration: 0.28)) { frame = fresh }
                }
            }
        }
    }
}

import CoreGraphics
import Foundation
import Observation
import ParallaxPlayback
import ParallaxSubtitles

/// Drives the settings preview through the REAL subtitle pipeline: the same
/// `SubtitleRenderer`, the same converted-script synthesis (CJK font planning
/// and size compensation included), and the same style-override mapping the
/// player overlay pushes (`convertedRendererOverride` — one function, so the
/// preview CANNOT drift from playback). The rendered bitmap is the preview.
///
/// The simulated session is a fullscreen landscape playback of a 16:9 video on
/// this device — the geometry the tuned cue sizes are authored against.
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
    @ObservationIgnored private var chain: Task<Void, Never>?

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
        // Fullscreen landscape surface of this device, 16:9 picture aspect-fit
        // into it — `videoRect` exactly as `SubtitleOverlayView` derives it.
        let surface = CGSize(
            width: max(stageSize.width, stageSize.height),
            height: min(stageSize.width, stageSize.height)
        )
        let storage = CGSize(width: 1920, height: 1080)
        let fit = min(surface.width / storage.width, surface.height / storage.height)
        let rect = CGRect(x: 0, y: 0, width: storage.width * fit, height: storage.height * fit)
        let override = style.convertedRendererOverride(surface: surface, videoRect: rect)

        pointScale = displayScale
        lift = style.verticalOffsetRatio * surface.height

        // Submission order — rapid slider edits must land last-edit-wins, the
        // same discipline as the player's style push chain. The renderer is
        // captured per task: a design change swaps the instance mid-chain.
        let needsLoad = !loaded
        loaded = true
        let previous = chain
        chain = Task { [renderer] in
            await previous?.value
            if needsLoad {
                try? await renderer.load(Data(Self.sampleSRT.utf8), format: .srt)
            }
            await renderer.setCanvas(size: rect.size, scale: displayScale, storageSize: storage)
            await renderer.setStyleOverride(override)
            guard !Task.isCancelled else { return }
            // nil = nothing changed since the last render — keep what's shown.
            if let fresh = await renderer.frame(at: 2.0) { frame = fresh }
        }
    }
}

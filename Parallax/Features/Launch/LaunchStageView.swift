import SwiftUI
import ParallaxCore

/// One frame of the launch story: field + sketched rings + (light mode) halo
/// and focus-snap flash, with the iris hole cut out so the real app shows
/// through beneath. Pure function of `(storyTime, holdPhase, size, scheme)` —
/// the clock lives in `LaunchRevealHost`, the math in `ParallaxCore`.
struct LaunchStageView: View {
    let storyTime: Double
    let holdPhase: Double?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let frame = LaunchFrame.evaluate(
                storyTime: storyTime,
                holdPhase: holdPhase,
                irisTargetScale: LaunchStageMetrics.irisTargetScale(
                    width: size.width, height: size.height
                )
            )
            Self.draw(frame, in: &context, size: size, palette: .current(for: colorScheme))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static func draw(
        _ frame: LaunchFrame,
        in context: inout GraphicsContext,
        size: CGSize,
        palette: LaunchPalette
    ) {
        let unit = LaunchStageMetrics.unit(width: size.width, height: size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let clipRadius = frame.clipRadius * unit

        // Field, with the iris hole cut out (the app beneath shows through).
        let holePath: Path? = clipRadius > 0
            ? Path(ellipseIn: CGRect(
                x: center.x - clipRadius, y: center.y - clipRadius,
                width: clipRadius * 2, height: clipRadius * 2
            ))
            : nil
        let fieldRect = Path(CGRect(origin: .zero, size: size))
        let fieldShading = GraphicsContext.Shading.radialGradient(
            palette.fieldGradient,
            center: CGPoint(x: size.width / 2, y: size.height * palette.fieldCenterY),
            startRadius: 0,
            endRadius: 0.66 * max(size.width, size.height)
        )
        context.drawLayer { field in
            if let holePath {
                field.clip(to: holePath, options: .inverse)
            }
            field.fill(fieldRect, with: fieldShading)
        }

        // Soft open: the handoff fades its home layer in (`homeOp`) under the
        // growing hole. Our home is the real app BENEATH the canvas, so the
        // same crossfade is drawn the other way around — a lid of field
        // shading over the hole, fading out — which is compositionally
        // identical (field × (1−homeOp) over app) without blending the app
        // toward the bare window (that flashed white in light mode).
        if let holePath, frame.homeOpacity < 1 {
            context.drawLayer { lid in
                lid.opacity = 1 - frame.homeOpacity
                lid.clip(to: holePath)
                lid.fill(fieldRect, with: fieldShading)
            }
        }

        // Brand halo — sits above the opening hole, like the handoff's layering.
        if let haloGradient = palette.haloGradient, frame.haloOpacity > 0.001 {
            let radius = LaunchStageMetrics.haloDiameter / 2 * unit
            context.drawLayer { layer in
                layer.opacity = frame.haloOpacity
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .radialGradient(haloGradient, center: center, startRadius: 0, endRadius: radius)
                )
            }
        }

        let radius = LaunchStageMetrics.ringRadius * unit
        let stroke = StrokeStyle(
            lineWidth: LaunchStageMetrics.mainStrokeWidth * unit,
            lineCap: .round, lineJoin: .round
        )
        // Thin icon understroke in the mono poses, equal partner while chromatic.
        let ghostWidth = LaunchStageMetrics.ghostStrokeWidth
            + (LaunchStageMetrics.mainStrokeWidth - LaunchStageMetrics.ghostStrokeWidth) * frame.colorMix
        let ghostStroke = StrokeStyle(
            lineWidth: ghostWidth * unit,
            lineCap: .round, lineJoin: .round
        )
        let offset = CGSize(
            width: frame.pairOffset.x * unit,
            height: frame.pairOffset.y * unit
        )

        // The rings, in their own layer: the soft-focus blur and the group
        // scale (entrance settle / breath pulse / iris blow-up) are scoped
        // HERE, so the flash below stays unblurred and unscaled like the
        // handoff's separate layer — no inverse-transform gymnastics.
        context.drawLayer { rings in
            if frame.ringBlur > 0.01 {
                rings.addFilter(.blur(radius: frame.ringBlur * unit))
            }
            rings.translateBy(x: center.x, y: center.y)
            rings.scaleBy(x: frame.ringScale, y: frame.ringScale)
            rings.translateBy(x: -center.x, y: -center.y)

            // Chromatic sketched pair: the GROUP blends onto the field
            // (screen on ink, multiply on paper); the two lines composite
            // normally with each other inside it, exactly like the handoff's
            // mix-blend-mode group.
            if frame.chromaOpacity > 0.001 {
                rings.opacity = frame.chromaOpacity
                rings.blendMode = frame.colorMix > 0.5 ? palette.chromaBlend : .normal
                rings.drawLayer { chroma in
                    chroma.drawLayer { main in
                        transformRing(&main, center: center, offset: CGSize(width: -offset.width, height: -offset.height), degrees: -frame.twistDegrees)
                        main.stroke(
                            ringPath(center: center, radius: radius, turns: frame.turns,
                                     wobble: frame.wobble, seed: LaunchStageMetrics.mainSeed,
                                     phase: frame.flowPhase),
                            with: .color(launchLerp(palette.pencil, palette.chromaMain, frame.colorMix)),
                            style: stroke
                        )
                    }
                    chroma.drawLayer { ghost in
                        ghost.opacity = palette.ghostOpacity + (1 - palette.ghostOpacity) * frame.colorMix
                        transformRing(&ghost, center: center, offset: offset, degrees: frame.twistDegrees)
                        ghost.stroke(
                            ringPath(center: center, radius: radius, turns: frame.turns,
                                     wobble: frame.wobble * LaunchStageMetrics.ghostWobbleFactor,
                                     seed: LaunchStageMetrics.ghostSeed, phase: -frame.flowPhase),
                            with: .color(launchLerp(palette.pencil, palette.chromaGhost, frame.colorMix)),
                            style: ghostStroke
                        )
                    }
                }
                rings.blendMode = .normal
                rings.opacity = 1
            }

            // The merged outcome ring — a single near-clean line in the icon's
            // pencil color. Zero until the merge moment, never earlier.
            if frame.mergedOpacity > 0.001 {
                rings.opacity = frame.mergedOpacity
                rings.stroke(
                    ringPath(center: center, radius: radius, turns: frame.turns,
                             wobble: frame.trackWobble * LaunchStageMetrics.mergedWobbleFactor,
                             seed: LaunchStageMetrics.mainSeed, phase: 0),
                    with: .color(launchColor(palette.pencil)),
                    style: stroke
                )
            }
        }

        // Focus-snap bloom at the merge (light mode only) — above the rings,
        // outside their blur/scale layer; only `flashScale` sizes it.
        if let flashGradient = palette.flashGradient, frame.flashOpacity > 0.001 {
            let radius = LaunchStageMetrics.flashDiameter / 2 * unit * frame.flashScale
            context.drawLayer { layer in
                layer.opacity = frame.flashOpacity
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .radialGradient(flashGradient, center: center, startRadius: 0, endRadius: radius)
                )
            }
        }
    }

    /// SVG `translate(±offset) rotate(±twist around center)` — the per-ring
    /// parallax transform from the handoff, ported operation-for-operation.
    private static func transformRing(
        _ context: inout GraphicsContext, center: CGPoint, offset: CGSize, degrees: Double
    ) {
        context.translateBy(x: offset.width, y: offset.height)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: .degrees(degrees))
        context.translateBy(x: -center.x, y: -center.y)
    }

    private static func ringPath(
        center: CGPoint, radius: Double, turns: Double,
        wobble: Double, seed: Double, phase: Double
    ) -> Path {
        let points = LaunchRingGeometry.points(
            center: SIMD2(center.x, center.y), radius: radius,
            turns: turns, wobble: wobble, seed: seed, phase: phase
        )
        var path = Path()
        path.move(to: CGPoint(x: points[0].x, y: points[0].y))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        return path
    }
}

// MARK: - Diagnostic previews
//
// Frozen story beats for pixel comparison against the handoff prototype
// (which freezes the same instants via its `__lxApply` hook). Permanent
// assets — keep them in sync with the spec's timeline table.

#Preview("Icon open — t 0.15") {
    LaunchStageView(storyTime: 0.15, holdPhase: nil)
}

#Preview("Chromatic crossfade — t 0.80") {
    LaunchStageView(storyTime: 0.80, holdPhase: nil)
}

#Preview("Sync hold — mid breath") {
    LaunchStageView(storyTime: 0.9, holdPhase: 0.3)
}

#Preview("Merge snap — t 2.06") {
    LaunchStageView(storyTime: 2.06, holdPhase: nil)
}

#Preview("Iris soft-open — t 2.64 (lid half-faded over green)") {
    ZStack {
        Color.green.ignoresSafeArea()
        LaunchStageView(storyTime: 2.64, holdPhase: nil)
    }
}

#Preview("Iris opening — t 2.85 (checker reveals hole)") {
    ZStack {
        // High-contrast underlay so the reveal hole is unmistakable.
        Color.green.ignoresSafeArea()
        LaunchStageView(storyTime: 2.85, holdPhase: nil)
    }
}

#Preview("Blur-out tail — t 3.30") {
    ZStack {
        Color.green.ignoresSafeArea()
        LaunchStageView(storyTime: 3.30, holdPhase: nil)
    }
}

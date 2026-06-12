import Foundation

// Keyframe math for the app-opening animation — a 1:1 port of the design
// handoff's `opening.jsx` timeline (story-seconds master clock, per-track
// keyframes, segment easings). Values here ARE the locked spec; change them
// only against an updated handoff. Rendering lives in the app target
// (`LaunchStageView`); this file knows nothing about views.
//
// All lengths are in "reference units": the handoff's 1920×1080 canvas, where
// the ring radius is 172 against a 1080 minimum dimension. The renderer
// multiplies by `LaunchStageMetrics.unit(width:height:)` to get points.

// MARK: - Easing

/// Segment easing curves from the handoff (`easeInOut` is the default).
enum LaunchEase: Sendable {
    case inOut, out, `in`, inExpo, outBack

    func callAsFunction(_ u: Double) -> Double {
        switch self {
        case .inOut: u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        case .out: 1 - pow(1 - u, 3)
        case .in: u * u * u
        case .inExpo: u <= 0 ? 0 : pow(2, 10 * u - 10)
        case .outBack: 1 + 2.9 * pow(u - 1, 3) + 1.9 * pow(u - 1, 2)
        }
    }
}

// MARK: - Keyframe track

/// One keyframe: the track eases INTO this stop from the previous one.
struct LaunchKeyStop: Sendable {
    var t: Double
    var v: Double
    var ease: LaunchEase = .inOut
}

/// Piecewise-eased interpolation over `stops`, clamped at both ends.
func launchTrack(_ t: Double, _ stops: [LaunchKeyStop]) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if t <= first.t { return first.v }
    if t >= last.t { return last.v }
    for i in 0 ..< (stops.count - 1) {
        let a = stops[i], b = stops[i + 1]
        if t >= a.t && t <= b.t {
            let u = (t - a.t) / (b.t - a.t)
            return a.v + (b.v - a.v) * b.ease(u)
        }
    }
    return last.v
}

// MARK: - Stage metrics

/// Geometry constants of the brand mark and stage, in reference units.
/// The recipe mirrors the app icon's construction — if the icon changes,
/// mirror it here (radius/stroke ratio, separation, wobble, seeds).
public enum LaunchStageMetrics {
    /// The handoff canvas' minimum dimension; lengths scale by `min(w, h) / 1080`.
    public static let referenceMinDimension = 1080.0
    public static let ringRadius = 172.0
    /// Inner radius of the merged ring's hole — the iris reveal clip.
    public static let irisInnerRadius = 158.0
    /// Main + merged line weight, measured off the shipped icon (20.9 px at
    /// R 256.5 in the 1024 asset → ratio 0.0816). The handoff's 15 was ~7%
    /// heavier than the mark it cites.
    public static let mainStrokeWidth = 14.0
    /// The icon draws the ghost ("second viewpoint") as a thinner understroke
    /// (13.4 px at R 256.5 → ratio 0.052). In the mono poses the animation
    /// mirrors that; the chromatic working pair renders as equals, so the
    /// ghost's weight lerps to `mainStrokeWidth` with the color story —
    /// the same device as its 0.34 → 1 opacity lerp.
    public static let ghostStrokeWidth = 9.0
    /// The icon's pencil double-line offset; each ring starts ±this from center.
    public static let iconSeparation = 16.0
    public static let baseWobble = 0.03
    public static let mainSeed = 0.7
    public static let ghostSeed = 2.4
    /// The ghost line is sketched a little rougher than the main line.
    public static let ghostWobbleFactor = 1.25
    /// The merged outcome ring is nearly clean.
    public static let mergedWobbleFactor = 0.35
    public static let haloDiameter = 1100.0
    public static let flashDiameter = 1400.0

    /// The revealed app's entrance scale; it settles to 1 as the iris opens.
    /// Driven by the HOST as a one-shot animation over
    /// `LaunchClock.settleStart...settleEnd` — deliberately not a frame field,
    /// so the canvas and the content transform can't double-drive the settle.
    public static let homeSettleScale = 1.09

    /// The spec's iris scale at its t=3.2 keyframe on its own 16:9 canvas.
    public static let specIrisTargetScale = 9.2
    /// The spec's iris scale at the very end of the story (blur-out tail).
    public static let specIrisEndScale = 12.0
    /// How far past the canvas corner the spec's iris opens (9.2 × 158 ÷ corner distance).
    static let irisCoverMargin = specIrisTargetScale * irisInnerRadius
        / ((1920.0 * 1920.0 + 1080.0 * 1080.0).squareRoot() / 2)

    /// Points per reference unit for a stage of the given size.
    public static func unit(width: Double, height: Double) -> Double {
        min(width, height) / referenceMinDimension
    }

    /// Iris scale at the t=3.2 keyframe so the reveal clears this stage's corners
    /// with the same margin the spec has on 16:9. Returns exactly 9.2 there.
    public static func irisTargetScale(width: Double, height: Double) -> Double {
        let corner = (width * width + height * height).squareRoot() / 2
        return irisCoverMargin * corner / (irisInnerRadius * unit(width: width, height: height))
    }
}

// MARK: - Frame

/// Everything the renderer needs for one frame of the launch story.
/// Lengths in reference units, angles in degrees.
public struct LaunchFrame: Equatable, Sendable {
    public var storyTime: Double

    /// Uniform scale of the whole ring group around stage center
    /// (entrance settle × hold breath pulse × iris blow-up).
    public var ringScale: Double
    /// Gaussian blur over the ring group (soft focus-in, motion-blur out).
    public var ringBlur: Double
    /// The main ring translates by −this, the ghost by +this.
    public var pairOffset: SIMD2<Double>
    /// Counter-twist: main rotates −this, ghost +this, around stage center.
    public var twistDegrees: Double

    /// Pencil overshoot tail (1.0 = sealed circle).
    public var turns: Double
    /// Live roughness for the sketched pair (breathes during the hold).
    public var wobble: Double
    /// Track roughness (hold-independent) — the merged ring's basis.
    public var trackWobble: Double
    /// Wobble-lobe drift around the ring: main +this, ghost −this.
    public var flowPhase: Double

    /// 0 = icon mono pencil, 1 = chromatic working pair.
    public var colorMix: Double
    public var chromaOpacity: Double
    /// The merged outcome ring — zero until the merge, never earlier.
    public var mergedOpacity: Double
    public var haloOpacity: Double
    public var flashOpacity: Double
    public var flashScale: Double

    /// Iris clip radius (0 = sealed; the reveal hole once > 0).
    public var clipRadius: Double
    /// Drives the soft-open lid over the fresh hole (the handoff's `homeOp`).
    /// The content settle scale is NOT here — see `homeSettleScale`.
    public var homeOpacity: Double

    /// Evaluates the timeline at `storyTime`, with `holdPhase` ∈ [0, 1) while
    /// pinned in the sync-hold loop (nil outside it). `irisTargetScale` is the
    /// stage-adapted t=3.2 iris keyframe (`LaunchStageMetrics.irisTargetScale`).
    public static func evaluate(
        storyTime t: Double,
        holdPhase: Double? = nil,
        irisTargetScale: Double = LaunchStageMetrics.specIrisTargetScale
    ) -> LaunchFrame {
        let end = LaunchClock.activeEnd
        let iconSep = LaunchStageMetrics.iconSeparation

        // Open ON THE ICON: the rings start at the icon's own offset, twist
        // apart in place, then register to a merged single line (restSep 0).
        let sep = launchTrack(t, [
            .init(t: 0, v: iconSep), .init(t: 0.78, v: iconSep, ease: .out),
            .init(t: 1.34, v: iconSep + 9), .init(t: 1.9, v: 0),
            .init(t: 2.06, v: 0, ease: .outBack), .init(t: end, v: 0),
        ])
        // Sketch → true circle as they merge.
        let wob = launchTrack(t, [
            .init(t: 0, v: LaunchStageMetrics.baseWobble), .init(t: 0.78, v: LaunchStageMetrics.baseWobble),
            .init(t: 1.9, v: 0), .init(t: end, v: 0),
        ])
        let turns = launchTrack(t, [
            .init(t: 0, v: 1.06), .init(t: 0.78, v: 1.06),
            .init(t: 1.9, v: 1.0, ease: .out), .init(t: end, v: 1.0),
        ])
        let blur = launchTrack(t, [
            .init(t: 0, v: 7), .init(t: 0.42, v: 0.8, ease: .out), .init(t: 0.72, v: 0),
            .init(t: 2.55, v: 0), .init(t: 3.2, v: 7, ease: .in), .init(t: end, v: 12),
        ])
        let rot = launchTrack(t, [
            .init(t: 0, v: 0), .init(t: 0.78, v: 0), .init(t: 1.34, v: 5),
            .init(t: 1.96, v: 0, ease: .outBack), .init(t: end, v: 0),
        ])
        let coreScale = launchTrack(t, [
            .init(t: 0, v: 0.92), .init(t: 0.5, v: 1.0, ease: .out), .init(t: 1.84, v: 1.0),
            .init(t: 1.98, v: 1.05, ease: .out), .init(t: 2.14, v: 1.0), .init(t: end, v: 1.0),
        ])
        let irisScale = launchTrack(t, [
            .init(t: 2.5, v: 1.0), .init(t: 3.2, v: irisTargetScale, ease: .inExpo),
            .init(t: end, v: irisTargetScale
                * (LaunchStageMetrics.specIrisEndScale / LaunchStageMetrics.specIrisTargetScale)),
        ])

        let chromaOp = launchTrack(t, [
            .init(t: 0, v: 0), .init(t: 0.34, v: 1, ease: .out), .init(t: 1.96, v: 1),
            .init(t: 2.62, v: 0.9), .init(t: 2.98, v: 0, ease: .in),
        ])
        let whiteOp = launchTrack(t, [
            .init(t: 0, v: 0), .init(t: 1.92, v: 0), .init(t: 2.06, v: 1, ease: .out),
            .init(t: 2.72, v: 1), .init(t: 3.1, v: 0, ease: .in),
        ])
        let haloOp = launchTrack(t, [
            .init(t: 0, v: 0), .init(t: 0.42, v: 0.6, ease: .out), .init(t: 1.3, v: 0.55),
            .init(t: 1.98, v: 0.95, ease: .out), .init(t: 2.24, v: 0.6),
            .init(t: 2.62, v: 0.5), .init(t: 3.06, v: 0, ease: .in),
        ])
        let flashOp = launchTrack(t, [
            .init(t: 1.86, v: 0), .init(t: 1.98, v: 0.55, ease: .out),
            .init(t: 2.24, v: 0, ease: .in), .init(t: end, v: 0),
        ])
        let flashScale = launchTrack(t, [
            .init(t: 1.86, v: 0.5), .init(t: 1.98, v: 0.9, ease: .out),
            .init(t: 2.26, v: 1.15, ease: .out), .init(t: end, v: 1.15),
        ])
        let homeOp = launchTrack(t, [
            .init(t: 2.58, v: 0), .init(t: 2.72, v: 1, ease: .out), .init(t: end, v: 1),
        ])

        // Color story: open AS the icon (mono) → chromatic while working →
        // resolve back to mono BEFORE the lines finish merging.
        var colorT = launchTrack(t, [
            .init(t: 0.55, v: 0), .init(t: 0.9, v: 1), .init(t: 1.5, v: 1), .init(t: 1.9, v: 0),
        ])

        // Sync-hold flow ("eddy", locked): the sketched rings roll gently in
        // place. Every term is periodic in the phase, so each breath cycle
        // loops seamlessly — and the cycle boundary matches the t=0.9 pose.
        var offset = SIMD2(sep, 0.0)
        var twist = rot
        var scale = coreScale * irisScale
        var wobble = wob
        var flowPhase = 0.0
        if let holdPhase {
            let ph = holdPhase * 2 * .pi
            let pulse = 0.5 - 0.5 * cos(ph)
            let k = LaunchClock.flowAmplitude
            offset = SIMD2(iconSep * (0.85 + 0.15 * cos(ph)), iconSep * 0.08 * sin(ph))
            twist = 1.6 * k * sin(ph)
            scale = coreScale * (1 + 0.012 * pulse) * irisScale
            wobble = LaunchStageMetrics.baseWobble + 0.014 * k * pulse
            flowPhase = ph
            colorT = 1  // fully chromatic for the whole hold
        }

        return LaunchFrame(
            storyTime: t,
            ringScale: scale,
            ringBlur: blur,
            pairOffset: offset,
            twistDegrees: twist,
            turns: turns,
            wobble: wobble,
            trackWobble: wob,
            flowPhase: flowPhase,
            colorMix: colorT,
            chromaOpacity: chromaOp,
            mergedOpacity: whiteOp,
            haloOpacity: haloOp,
            flashOpacity: flashOp,
            flashScale: flashScale,
            clipRadius: irisScale > 1.001 ? LaunchStageMetrics.irisInnerRadius * irisScale : 0,
            homeOpacity: homeOp
        )
    }
}

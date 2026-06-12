import Foundation

/// The hand-drawn ring polyline — the same recipe as the app icon's mark.
/// `wobble` is the sketch roughness (0 = a true circle), `turns` > 1 gives the
/// pencil's overshoot tail, `phase` drifts the wobble lobes around the ring
/// (the sync-hold "flow").
public enum LaunchRingGeometry {
    public static func points(
        center: SIMD2<Double>,
        radius: Double,
        turns: Double,
        wobble: Double,
        seed: Double,
        phase: Double = 0,
        segments: Int = 144
    ) -> [SIMD2<Double>] {
        let start = -1.85
        let total = 2 * .pi * turns
        return (0 ... segments).map { i in
            let a = start + Double(i) / Double(segments) * total
            let r = radius * (
                1 + wobble * sin(3 * a + seed + phase)
                  + wobble * 0.45 * sin(5 * a + 1.7 * seed - phase)
            )
            return center + SIMD2(r * cos(a), r * sin(a))
        }
    }
}

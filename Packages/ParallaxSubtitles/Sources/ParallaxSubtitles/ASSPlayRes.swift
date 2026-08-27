import CoreGraphics

/// The canvas an ASS script's units are expressed in.
///
/// A script may declare one dimension, both, or neither, and libass fills the
/// gaps itself in `ass_lazy_track_init` — but only at the first rendered frame,
/// and it exposes no accessor. This mirrors that function exactly (libass
/// 0.17.5, `ass.c`), so the resolution is known the moment a track is parsed:
/// border and shadow are script-unit lengths, and pushing a value measured
/// against the wrong canvas is what makes a 1080p fansub's ring look half as
/// heavy as a 720p one's.
enum ASSPlayRes {

    /// libass' fallback when a script declares neither dimension.
    static let assumed = CGSize(width: 384, height: 288)

    static func effective(x: Int, y: Int) -> CGSize {
        if x > 0, y > 0 { return CGSize(width: x, height: y) }
        if x <= 0, y <= 0 { return assumed }
        if y <= 0 {
            // 1280 is special-cased upstream: those scripts are 1280x1024 by
            // convention, not 4:3 of the width.
            let height = x == 1280 ? 1024 : max(1, (x - 1) - (x - 1) / 4)
            return CGSize(width: x, height: height)
        }
        return CGSize(width: y == 1024 ? 1280 : y + y / 3, height: y)
    }
}

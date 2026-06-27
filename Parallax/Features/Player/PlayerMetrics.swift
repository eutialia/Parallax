import SwiftUI

/// Every player dimension derived from the design's unit scale `u = width / 1920`.
/// The big-screen player (tvOS + iPad) is authored at a 1920-wide base; tvOS renders
/// at `u = 1.0`, a 1366-wide iPad at `u ≈ 0.711`, so the two platforms stay visually
/// identical — just scaled. Control sizes at u=1.0 target the HIG's tvOS metrics:
/// 66pt buttons (the documented default; 56 is the floor), ≥23pt text, and gaps sized
/// so the 1.06 focus lift can't crowd a neighbour. The iPhone player is authored
/// separately: its round-button sizes are the fixed `phone*` statics below, but its
/// chips and progress bar reuse these formulas at the fixed `.phone` scale.
struct PlayerMetrics: Equatable {
    /// Which layout family the metrics belong to. Stored because `u` alone can't
    /// tell the classes apart (phone's fixed 0.7 ≈ a 12.9" iPad's 0.711) and a few
    /// metrics — subtitles — anchor on viewing distance, not canvas scale.
    enum DeviceClass { case phone, pad, tv }

    let u: CGFloat
    let deviceClass: DeviceClass

    /// Big-screen metrics for an actual point width, clamped so a small multitasking
    /// iPad window can't shrink controls to nothing and tvOS never exceeds the 1.0 base.
    /// iPad callers pass the window's LARGER dimension (`max(width, height)`), not the
    /// current width — controls keep one size across portrait/landscape, like every
    /// native app's 44pt stays 44pt; only the window class (full screen vs multitask)
    /// changes the scale.
    init(width: CGFloat) {
        self.u = min(max(width / 1920, 0.5), 1.0)
        self.deviceClass = .pad
    }

    private init(u: CGFloat, deviceClass: DeviceClass) {
        self.u = u
        self.deviceClass = deviceClass
    }

    /// Fixed iPhone scale for chips + progress. 0.7 sizes the chips (`66u ≈ 46pt`) to
    /// the phone's `phone*` round-button statics and the time labels to ~17pt — the
    /// handoff's 0.92 read oversized next to them.
    static let phone = PlayerMetrics(u: 0.7, deviceClass: .phone)
    /// tvOS full scale.
    static let tv = PlayerMetrics(u: 1.0, deviceClass: .tv)

    /// Device-correct metrics for a player surface — the one place the player maps
    /// hardware to a layout family: tvOS full scale, iPad from the window's larger
    /// dimension, iPhone the fixed phone scale. Deliberately `UIDevice`-based, not
    /// size-class-based (a Pro Max in landscape reports `.regular` but must stay on
    /// the phone layout) — mirroring `PlayerControlsView`'s split.
    /// `@MainActor` for `UIDevice.current`: the `View`-body callers were already
    /// isolated; the annotation keeps that guarantee explicit on this plain struct.
    @MainActor
    static func forSurface(_ size: CGSize) -> PlayerMetrics {
        #if os(tvOS)
        .tv
        #else
        UIDevice.current.userInterfaceIdiom == .pad
            ? PlayerMetrics(width: max(size.width, size.height))
            : .phone
        #endif
    }

    // Layout (big screens)
    /// 80 at u=1.0 — the documented tvOS side safe-area inset; the full-width track
    /// and the control row both end on it.
    var padX: CGFloat { 80 * u }
    /// Directional HUD reveal distance: the top bar parks this far above its resting
    /// spot while hidden, the bottom rows this far below (the center transport stays
    /// put), so show/hide converges on the video instead of one flat fade.
    var hudSlide: CGFloat { 12 * u }
    /// Equal to `controlRowBottom` by design — top and bottom chrome carry the same
    /// edge margin (the top bar adds the latched status-bar inset on top of this).
    var topBarTop: CGFloat { 54 * u }
    var controlRowBottom: CGFloat { 54 * u }
    /// 24 at u=1.0 — the HIG's spacing floor for bezel-less controls, so a focused
    /// chip's 1.06 lift + shadow clears its neighbour instead of crowding it.
    var chipsGap: CGFloat { 24 * u }
    /// One bottom inset and one track/label scale for BOTH the full-HUD scrubber and
    /// the minimal scrub bar, so the floor↔HUD switch reads as the same bar persisting
    /// (only the handle, bubble, and ticks change) instead of a jump-cut.
    var progressBottom: CGFloat { 148 * u }

    /// The full-HUD scrubber's resting placement — the ONE source the HUD scrubber AND
    /// the double-tap / scrub bar both pad by, so the two are pixel-identical in height
    /// and width (the tvOS lesson: a seek bar at a different spot than the HUD scrubber
    /// reads as a jump). iPhone is authored at its fixed `phone*` insets; iPad/tvOS ride
    /// the big-screen formulas. Both surfaces respect the safe area, so equal pads land
    /// on the same screen point.
    var scrubberInsetX: CGFloat { deviceClass == .phone ? Self.phonePadX : padX }
    var scrubberBottom: CGFloat { deviceClass == .phone ? Self.phoneProgressBottom : progressBottom }

    // Progress
    var trackHeight: CGFloat { 8 * u }
    var progressRowGap: CGFloat { 20 * u }
    /// 24 at u=1.0 — above the HIG's 23pt tvOS text floor (the old 20 sat below it).
    var timeLabelSize: CGFloat { 24 * u }
    var chapterTickWidth: CGFloat { 3 * u }
    var handleDiameter: CGFloat { 22 * u }
    var handleDiameterFocused: CGFloat { 26 * u }
    var scrubHandleWidth: CGFloat { 7 * u }
    /// 44 at u=1.0 — under 2× the 24u end labels; the old 54 dwarfed them.
    var scrubBubbleSize: CGFloat { 44 * u }
    var scrubChapterSize: CGFloat { 22 * u }

    // Centre transport (iPad)
    var transportSkip: CGFloat { 96 * u }
    var transportPlay: CGFloat { 140 * u }
    var transportGap: CGFloat { 76 * u }
    /// tvOS paused-status glyph (PlayerPausedOverlay) — keep equal to the iPad
    /// play disc's glyph (`transportPlay × 0.46`) so the two platforms' center
    /// pause marks are the same drawing at the same scale.
    var pausedGlyph: CGFloat { 64 * u }

    // Buttons / chips — 72 at u=1.0: one step above the HIG's 66pt tvOS default,
    // sized to the TV app's player chrome; iPad (u ≈ 0.61) lands exactly on the
    // 44pt iOS control default. (56 is the tvOS minimum the old 54/58 sat under.)
    var closeSize: CGFloat { 72 * u }
    // iPhone chips are authored at fixed, compact sizes (the `phoneChip*` statics) rather
    // than `72 * u`: the u-scaled chip was ~50pt tall and the four-to-five-chip row crowded
    // the bottom edge against the home indicator in landscape (the only orientation iPhone
    // plays in). The scrubber still rides `u`, so only the chips shrink. tvOS/iPad keep the
    // big-screen formula.
    var chipHeight: CGFloat { deviceClass == .phone ? Self.phoneChipHeight : 72 * u }
    var chipPadX: CGFloat { deviceClass == .phone ? Self.phoneChipPadX : 20 * u }
    var chipGap: CGFloat { deviceClass == .phone ? Self.phoneChipGap : 9 * u }
    var chipFontSize: CGFloat { deviceClass == .phone ? Self.phoneChipFontSize : 25 * u }
    var chipIconSize: CGFloat { deviceClass == .phone ? Self.phoneChipIconSize : 28 * u }

    // Split pill — height matches `chipHeight` so the pill rows with the chips.
    var splitPillHeight: CGFloat { 72 * u }
    var splitPillSegment: CGFloat { 80 * u }
    var splitPillIcon: CGFloat { 30 * u }

    // Title
    var titleSize: CGFloat { 38 * u }

    // Subtitles (client-rendered overlay — SubtitleOverlayView). Cue size tracks
    // viewing distance, not canvas scale, so each class anchors its own value:
    // one u-coefficient can't hold the iPad near its proven ~20pt (u ≈ 0.62–0.71)
    // while giving the 3-metre couch ~46pt (u = 1.0). iPad still scales with the
    // window class via u; phone is fixed like the other phone statics.
    /// tvOS 46 ≈ 4.3% of the 1080pt canvas (Apple's native player draws ~5%);
    /// iPad 32u ≈ 20–23pt full screen, floored at the phone's 20 so a small
    /// multitasking window (u clamps at 0.5 → 16) can't drop cues below the
    /// proven phone size; phone keeps the proven 20.
    var subtitleFontSize: CGFloat {
        switch deviceClass {
        case .phone: 20
        case .pad: max(20, 32 * u)
        case .tv: 46
        }
    }
    /// Cue rest distance from the bottom edge (the overlay is full-bleed).
    var subtitleBottom: CGFloat { deviceClass == .tv ? 64 : 48 }
    /// Side inset capping long lines; tvOS uses the 80pt action-safe margin.
    var subtitleInsetX: CGFloat { deviceClass == .tv ? 80 : 32 }

    // Scrims — loading ring + caption (see PlayerLoadingScrim).
    // ONE ring geometry for every flavor (buffering / audio switch / stall):
    // the modes cross-fade into each other over live video, so per-mode ring
    // sizes and caption metrics made the circle jump scale and height at every
    // flip (device-rejected). Only the dim differs per mode.
    var scrimRing: CGFloat { 92 * u }
    var scrimRingStroke: CGFloat { 5.5 * u }
    var scrimCaptionGap: CGFloat { 26 * u }
    var scrimCaptionLineGap: CGFloat { 6 * u }
    var scrimLabelSize: CGFloat { 24 * u }
    var scrimSubSize: CGFloat { 16 * u }

    // Scrims — double-tap seek flash (see PlayerSeekFlash)
    var seekChevronSize: CGFloat { 40 * u }
    var seekLabelSize: CGFloat { 23 * u }
    var seekContentGap: CGFloat { 18 * u }

    // Scrims — error surface (see PlayerErrorScrim)
    var errorChipSize: CGFloat { 78 * u }
    var errorGlyphSize: CGFloat { 38 * u }
    var errorTitleSize: CGFloat { 28 * u }
    var errorTitleTop: CGFloat { 24 * u }
    var errorBodySize: CGFloat { 18 * u }
    var errorBodyTop: CGFloat { 12 * u }
    var errorBodyMaxWidth: CGFloat { 520 * u }
    var errorDetailSize: CGFloat { 14 * u }
    var errorDetailTop: CGFloat { 18 * u }
    var errorDetailPadX: CGFloat { 16 * u }
    var errorDetailPadY: CGFloat { 12 * u }
    var errorDetailRadius: CGFloat { 10 * u }
    var errorDetailMaxWidth: CGFloat { 440 * u }
    var errorButtonSize: CGFloat { 19 * u }
    var errorButtonGap: CGFloat { 14 * u }
    var errorButtonsTop: CGFloat { 28 * u }

    // iPhone chrome layout — fixed values, not u-scaled: the phone HUD is authored at 1×
    // alongside its bespoke round-button sizes (see `PlayerControlsView.phoneControls`).
    // Named here so the phone layout has one home instead of scattered literals.
    static let phonePadX: CGFloat = 26
    static let phoneTopBarTop: CGFloat = 22
    static let phoneTopBarGap: CGFloat = 14
    static let phoneTransportGap: CGFloat = 46
    static let phoneChipRowGap: CGFloat = 8
    static let phoneChipRowBottom: CGFloat = 20
    static let phoneProgressBottom: CGFloat = 64
    static let phoneCloseSize: CGFloat = 44
    static let phoneTransportPlay: CGFloat = 84
    static let phoneTransportSkip: CGFloat = 58

    // iPhone chip pill — compact, fixed (see `chipHeight` and friends for why the phone
    // breaks from the `72 * u` big-screen formula). ~36pt tall reads like the system
    // player's track chips and clears the home indicator once the row is this short.
    static let phoneChipHeight: CGFloat = 36
    static let phoneChipPadX: CGFloat = 12
    static let phoneChipGap: CGFloat = 5
    static let phoneChipFontSize: CGFloat = 14
    static let phoneChipIconSize: CGFloat = 15
}

import SwiftUI

/// Every player dimension derived from the design's unit scale `u = width / 1920`.
/// The big-screen player (tvOS + iPad) is authored at a 1920-wide base; tvOS renders
/// at `u = 1.0`, a 1366-wide iPad at `u ≈ 0.711`, so the two platforms stay visually
/// identical — just scaled. The iPhone player is authored separately: its round-button
/// sizes are bespoke literals at the call site, but its chips and progress bar reuse
/// these formulas at the fixed `.phone` scale.
struct PlayerMetrics: Equatable {
    let u: CGFloat

    /// Big-screen metrics for an actual point width, clamped so a small multitasking
    /// iPad window can't shrink controls to nothing and tvOS never exceeds the 1.0 base.
    init(width: CGFloat) {
        self.u = min(max(width / 1920, 0.5), 1.0)
    }

    private init(u: CGFloat) { self.u = u }

    /// Fixed iPhone scale for chips + progress. 0.7 sizes the chips (`54u ≈ 38pt`) to
    /// the phone's bespoke 37–40pt round buttons and the time labels to 14pt — the
    /// handoff's 0.92 read oversized next to them and ate track length with ~99pt
    /// label columns.
    static let phone = PlayerMetrics(u: 0.7)
    /// tvOS full scale.
    static let tv = PlayerMetrics(u: 1.0)

    // Layout (big screens)
    var padX: CGFloat { 60 * u }
    var topBarTop: CGFloat { 52 * u }
    var controlRowBottom: CGFloat { 54 * u }
    var chipsGap: CGFloat { 14 * u }
    /// One bottom inset and one track/label scale for BOTH the full-HUD scrubber and
    /// the minimal scrub bar, so the floor↔HUD switch reads as the same bar persisting
    /// (only the handle, bubble, and ticks change) instead of a jump-cut.
    var progressBottom: CGFloat { 148 * u }

    // Progress
    var trackHeight: CGFloat { 8 * u }
    var progressRowGap: CGFloat { 20 * u }
    var timeLabelWidth: CGFloat { 108 * u }
    var timeLabelSize: CGFloat { 20 * u }
    var chapterTickWidth: CGFloat { 3 * u }
    var handleDiameter: CGFloat { 22 * u }
    var handleDiameterFocused: CGFloat { 26 * u }
    var scrubHandleWidth: CGFloat { 7 * u }
    var scrubBubbleSize: CGFloat { 54 * u }
    var scrubChapterSize: CGFloat { 22 * u }

    // Centre transport (iPad)
    var transportSkip: CGFloat { 80 * u }
    var transportPlay: CGFloat { 120 * u }
    var transportGap: CGFloat { 68 * u }

    // Buttons / chips
    var closeSize: CGFloat { 58 * u }
    var chipHeight: CGFloat { 54 * u }
    var chipPadX: CGFloat { 20 * u }
    var chipGap: CGFloat { 9 * u }
    var chipFontSize: CGFloat { 20 * u }
    var chipIconSize: CGFloat { 23 * u }

    // Split pill
    var splitPillHeight: CGFloat { 56 * u }
    var splitPillSegment: CGFloat { 64 * u }
    var splitPillIcon: CGFloat { 26 * u }
    var splitPillDivider: CGFloat { 28 * u }

    // Title
    var titleSize: CGFloat { 38 * u }

    // iPhone chrome layout — fixed values, not u-scaled: the phone HUD is authored at 1×
    // alongside its bespoke round-button sizes (see `PlayerControlsView.phoneControls`).
    // Named here so the phone layout has one home instead of scattered literals.
    static let phonePadX: CGFloat = 26
    static let phoneTopBarTop: CGFloat = 22
    static let phoneTopBarGap: CGFloat = 14
    static let phoneTransportGap: CGFloat = 46
    static let phoneChipRowGap: CGFloat = 9
    static let phoneChipRowBottom: CGFloat = 18
    static let phoneProgressBottom: CGFloat = 64
}

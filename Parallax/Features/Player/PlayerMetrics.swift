import SwiftUI

/// Every player dimension derived from the design's unit scale `u = width / 1920`.
/// The big-screen player (tvOS + iPad) is authored at a 1920-wide base; tvOS renders
/// at `u = 1.0`, a 1366-wide iPad at `u ≈ 0.711`, so the two platforms stay visually
/// identical — just scaled. The iPhone player is authored separately: its round-button
/// sizes are bespoke literals at the call site, but its chips and progress bar reuse
/// these formulas at the fixed `.phone` scale (`u ≈ 0.92`) per the handoff.
struct PlayerMetrics: Equatable {
    let u: CGFloat

    /// Big-screen metrics for an actual point width, clamped so a small multitasking
    /// iPad window can't shrink controls to nothing and tvOS never exceeds the 1.0 base.
    init(width: CGFloat) {
        self.u = min(max(width / 1920, 0.5), 1.0)
    }

    private init(u: CGFloat) { self.u = u }

    /// Fixed iPhone scale for chips + progress (the handoff renders both at `u ≈ 0.92`).
    static let phone = PlayerMetrics(u: 0.92)
    /// tvOS full scale.
    static let tv = PlayerMetrics(u: 1.0)

    // Layout (big screens)
    var padX: CGFloat { 60 * u }
    var topBarTop: CGFloat { 52 * u }
    var controlRowBottom: CGFloat { 54 * u }
    var controlRowGap: CGFloat { 14 * u }
    var chipsGap: CGFloat { 14 * u }
    var chipsOffset: CGFloat { 22 * u }
    var progressBottomNormal: CGFloat { 148 * u }
    var progressBottomScrub: CGFloat { 168 * u }

    // Progress
    var trackHeightNormal: CGFloat { 8 * u }
    var trackHeightScrub: CGFloat { 14 * u }
    var progressRowGap: CGFloat { 20 * u }
    var timeLabelWidth: CGFloat { 108 * u }
    var timeLabelSize: CGFloat { 20 * u }
    var timeLabelScrubSize: CGFloat { 24 * u }
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
}

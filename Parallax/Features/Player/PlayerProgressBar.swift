import SwiftUI

/// The single layered progress bar for every platform and state — replaces the iOS
/// `Slider`, the tvOS focusable bar, and the old `ScrubBar`. Monochrome white over the
/// video scrim, panel-less. The track runs the full row width with the time labels
/// ABOVE its two ends (the tvOS system player's title-above-scrubber anatomy); during
/// `.scrub` the labels fade out — the floating bubble carries the time, and near either
/// end it would collide with them. Visual only: `played` is a 0...1 fraction the caller
/// supplies (live playback, a drag preview, or the reducer's scrub head). When
/// `onScrubChanged`/`onScrubEnded` are set (iOS), a drag anywhere on the bar scrubs
/// RELATIVE to the current position — grabbing the bar is grabbing the handle, from
/// wherever the finger lands; a plain tap is inert (no jump-to-tap seeking). tvOS
/// leaves the handlers nil and drives seeking via the remote, so no drag gesture is
/// attached there.
struct PlayerProgressBar: View {
    enum Mode: Equatable { case normal, focused, scrub }

    let metrics: PlayerMetrics
    var mode: Mode = .normal
    let played: Double
    /// 0...1 fraction the buffer extends to — the spec's middle layer (track
    /// `white 0.20` → buffered `white 0.36` → played `#fff`). Seeks inside it are
    /// instant (no server round-trip), so it doubles as the scrub affordance.
    /// Nil hides the layer (VLC path, or nothing buffered around the playhead).
    var buffered: Double? = nil
    let elapsed: String
    let remaining: String
    /// Seconds behind `elapsed`/`remaining` (and the bubble). They drive the
    /// `.numericText` content transitions, so an animated scrub change rolls the
    /// digits instead of cross-fading the whole label; unanimated updates (live
    /// playback ticks) run no transition either way.
    let elapsedSeconds: Double
    let remainingSeconds: Double
    /// Chapter start fractions (0...1); ticks render in every mode so the bar keeps
    /// its chapter landmarks across the HUD↔scrub switch instead of popping them in.
    var chapters: [Double] = []
    /// Big floating time + chapter label above the handle; `.scrub` only.
    var bubbleTime: String? = nil
    var bubbleChapter: String? = nil
    /// iOS drag handlers (nil on tvOS).
    var onScrubChanged: ((Double) -> Void)? = nil
    var onScrubEnded: ((Double) -> Void)? = nil

    private var trackH: CGFloat { metrics.trackHeight }
    private var labelSize: CGFloat { metrics.timeLabelSize }
    /// Reserve the tallest handle of ANY mode, not just the current one, so the row —
    /// and with it the track's vertical center — is identical across normal/focused/
    /// scrub and the HUD↔scrub switch can't shift the bar.
    private var rowHeight: CGFloat {
        max(trackH + 22 * metrics.u, metrics.handleDiameterFocused + 6 * metrics.u)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    var body: some View {
        VStack(spacing: 6 * metrics.u) {
            // Labels above the track ends. Opacity-hidden in `.scrub` (never a
            // structural `if`): the row's height is part of the bar's reserved
            // geometry, and unmounting it would shift the track on the HUD↔scrub
            // switch — the exact jump `rowHeight` exists to prevent.
            HStack(alignment: .firstTextBaseline, spacing: metrics.progressRowGap) {
                Text(elapsed)
                    .font(.system(size: labelSize, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: elapsedSeconds))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(remaining)
                    .font(.system(size: labelSize, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: remainingSeconds))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .opacity(mode == .scrub ? 0 : 1)

            GeometryReader { geo in
                let w = geo.size.width
                let p = clamp(played)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.20)).frame(height: trackH)
                    if let buffered {
                        Capsule().fill(.white.opacity(0.36))
                            .frame(width: w * clamp(buffered), height: trackH)
                    }
                    Capsule().fill(.white).frame(width: w * p, height: trackH)

                    ForEach(chapters, id: \.self) { c in
                        Rectangle()
                            .fill(c <= p ? Color.playerInk.opacity(0.5) : .white.opacity(0.5))
                            .frame(width: metrics.chapterTickWidth, height: trackH)
                            .offset(x: w * clamp(c) - metrics.chapterTickWidth / 2)
                    }

                    handle.offset(x: w * p - handleWidth / 2)

                    if mode == .scrub, let bubbleTime {
                        bubble(bubbleTime)
                            .position(x: w * p, y: -(bubbleHeight / 2 + 14 * metrics.u))
                    }
                }
                .frame(height: rowHeight, alignment: .center)
                #if os(tvOS)
                // No drag gesture on tvOS (the bar lives in a focusable Button) —
                // an extended hit rect would grow the Button's focus geometry.
                .contentShape(Rectangle())
                #else
                // Hit area only — visuals unchanged. The bar row is ~22-32pt;
                // the extension reaches the HIG 44pt touch floor and covers the
                // (non-interactive, scrub-faded) time labels above, so a grab
                // aimed slightly high still starts the scrub. TOP-only by
                // construction: the chips sit directly below with almost no
                // clearance (phone: the rows already touch).
                .contentShape(TopExtendedRectangle(
                    topExtension: max(28 * metrics.u, 44 - rowHeight)))
                // Same reach as the hit shape above: a drag that starts where a
                // scrub CAN start must never become a pull-to-dismiss.
                .pullToDismissExclusion(extendingTop: max(28 * metrics.u, 44 - rowHeight))
                #endif
                .modifier(ScrubGesture(width: w, played: p,
                                       onChanged: onScrubChanged, onEnded: onScrubEnded))
            }
            .frame(height: rowHeight)
        }
    }

    private var handleWidth: CGFloat {
        switch mode {
        case .normal: metrics.handleDiameter
        case .focused: metrics.handleDiameterFocused
        case .scrub: metrics.scrubHandleWidth
        }
    }

    /// ONE view identity across all three modes — width/height/radius retarget on a
    /// mode flip instead of crossfading two handle views. The structural `switch`
    /// this replaces ghosted during the normal↔scrub transition: the outgoing dot
    /// froze at its removal-time offset while the incoming pill tracked the finger,
    /// reading as a misaligned dot beside the scrub line (device-caught).
    private var handle: some View {
        RoundedRectangle(cornerRadius: handleCornerRadius, style: .continuous)
            .fill(.white)
            .frame(width: handleWidth, height: handleHeight)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: 3 * metrics.u)
                    .padding(-3 * metrics.u)
                    .opacity(mode == .focused ? 1 : 0)
            )
            .shadow(color: .black.opacity(0.5),
                    radius: (mode == .scrub ? 5 : 2) * metrics.u, y: 1)
    }

    private var handleHeight: CGFloat {
        switch mode {
        case .normal: metrics.handleDiameter
        case .focused: metrics.handleDiameterFocused
        case .scrub: trackH + 22 * metrics.u
        }
    }

    private var handleCornerRadius: CGFloat {
        mode == .scrub ? 5 * metrics.u : handleWidth / 2
    }

    /// Approximate so the bubble floats just above the handle; `.position` only needs the
    /// view's centre, and exact height isn't load-bearing here.
    private var bubbleHeight: CGFloat {
        metrics.scrubBubbleSize + (bubbleChapter == nil ? 0 : metrics.scrubChapterSize + 10 * metrics.u)
    }

    private func bubble(_ time: String) -> some View {
        VStack(spacing: 10 * metrics.u) {
            Text(time)
                .font(.system(size: metrics.scrubBubbleSize, weight: .bold).monospacedDigit())
                .contentTransition(.numericText(value: elapsedSeconds))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 20 * metrics.u, y: 2)
            if let bubbleChapter {
                Text(bubbleChapter)
                    .font(.system(size: metrics.scrubChapterSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
        .fixedSize()
    }
}

/// The scrub bar's hit region: the row's rect grown UPWARD only. Out-of-bounds
/// hits are delivered because no ancestor in the bar's chain clips — adding a
/// `.clipped()`/`.clipShape` anywhere above the scrubber would silently kill
/// the extra grab zone.
private struct TopExtendedRectangle: Shape {
    var topExtension: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - topExtension,
                    width: rect.width, height: rect.height + topExtension))
    }
}

/// Attaches the iOS drag-to-seek gesture ONLY when a handler is present, so the tvOS
/// path (handlers nil, bar driven by the remote inside a focusable Button) gets no
/// gesture that could fight the focus engine. `DragGesture` is unavailable on tvOS, so
/// the whole gesture path is compiled out there — the remote drives the bar instead.
///
/// The drag is RELATIVE: the displayed fraction is captured at drag start and the
/// finger's translation moves the playhead from there — grabbing any part of the bar
/// is grabbing the handle. (The old absolute `location.x / width` mapping made a bare
/// touch JUMP the playhead to the tap point.) `minimumDistance` keeps plain taps from
/// engaging at all: no jump, no pause, no seek.
private struct ScrubGesture: ViewModifier {
    let width: CGFloat
    /// The bar's currently displayed fraction — the relative drag's anchor.
    let played: Double
    let onChanged: ((Double) -> Void)?
    let onEnded: ((Double) -> Void)?
    @State private var startFraction: Double? = nil
    #if !os(tvOS)
    /// Gesture liveness. `onEnded` only fires when a drag SUCCEEDS — a system steal
    /// (home-indicator swipe under the bar, notification pull) cancels the gesture
    /// with no callback at all, which would strand `startFraction` AND the parent's
    /// whole scrub state (engine paused, chrome collapsed, next grab anchored at the
    /// old drag's start). `@GestureState` is the one thing the system resets even on
    /// cancellation, so its false-flip is the cancel signal.
    @GestureState private var dragActive = false
    /// The last fraction reported to `onChanged` — what a detected cancel commits.
    @State private var lastReported: Double? = nil
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        if onChanged == nil && onEnded == nil {
            content
        } else {
            content.gesture(
                DragGesture(minimumDistance: 9, coordinateSpace: .local)
                    .updating($dragActive) { _, active, _ in active = true }
                    .onChanged { v in
                        guard width > 0 else { return }
                        let base = startFraction ?? played
                        if startFraction == nil { startFraction = base }
                        let fraction = min(max(base + v.translation.width / width, 0), 1)
                        lastReported = fraction
                        onChanged?(fraction)
                    }
                    .onEnded { v in
                        guard width > 0 else { return }
                        let base = startFraction ?? played
                        startFraction = nil
                        lastReported = nil
                        onEnded?(min(max(base + v.translation.width / width, 0), 1))
                    }
            )
            // Cancellation path: `dragActive` resets to false with `lastReported`
            // still set only when the system killed the drag without `onEnded`.
            // Route it through the normal end at the last reported fraction so the
            // parent commits/resumes instead of stranding paused. (A normal end
            // clears `lastReported` first, so this never double-fires.)
            .onChange(of: dragActive) { _, active in
                guard !active, let fraction = lastReported else { return }
                startFraction = nil
                lastReported = nil
                onEnded?(fraction)
            }
        }
        #endif
    }
}

#Preview("normal / focused / scrub") {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 90) {
            PlayerProgressBar(metrics: .tv, mode: .normal, played: 0.5, buffered: 0.64,
                              elapsed: "1:04:18", remaining: "-1:02:42",
                              elapsedSeconds: 3858, remainingSeconds: 3762,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89])
            PlayerProgressBar(metrics: .tv, mode: .focused, played: 0.5, buffered: 0.64,
                              elapsed: "1:04:18", remaining: "-1:02:42",
                              elapsedSeconds: 3858, remainingSeconds: 3762,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89])
            PlayerProgressBar(metrics: .tv, mode: .scrub, played: 0.72, buffered: 0.81,
                              elapsed: "1:31:10", remaining: "-0:35:50",
                              elapsedSeconds: 5470, remainingSeconds: 2150,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89],
                              bubbleTime: "1:31:10", bubbleChapter: "Chapter 7 · The Drift")
        }
        .padding(60)
    }
    .frame(width: 1200, height: 700)
    .environment(\.colorScheme, .dark)
}

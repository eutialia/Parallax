import SwiftUI

/// The single layered progress bar for every platform and state — replaces the iOS
/// `Slider`, the tvOS focusable bar, and the old `ScrubBar`. Monochrome white over the
/// video scrim, panel-less. Visual only: `played` is a 0...1 fraction the caller
/// supplies (live playback, a drag preview, or the reducer's scrub head). When
/// `onScrubChanged`/`onScrubEnded` are set (iOS), a drag on the track reports the
/// fraction under the finger; tvOS leaves them nil and drives seeking via the remote,
/// so no drag gesture is attached there.
struct PlayerProgressBar: View {
    enum Mode: Equatable { case normal, focused, scrub }

    let metrics: PlayerMetrics
    var mode: Mode = .normal
    let played: Double
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
        HStack(spacing: metrics.progressRowGap) {
            Text(elapsed)
                .font(.system(size: labelSize, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: elapsedSeconds))
                .foregroundStyle(.white)
                .frame(minWidth: metrics.timeLabelWidth, alignment: .leading)

            GeometryReader { geo in
                let w = geo.size.width
                let p = clamp(played)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.20)).frame(height: trackH)
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
                .contentShape(Rectangle())
                .modifier(ScrubGesture(width: w, onChanged: onScrubChanged, onEnded: onScrubEnded))
            }
            .frame(height: rowHeight)

            Text(remaining)
                .font(.system(size: labelSize, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: remainingSeconds))
                .foregroundStyle(.white.opacity(0.62))
                .frame(minWidth: metrics.timeLabelWidth, alignment: .trailing)
        }
    }

    private var handleWidth: CGFloat {
        switch mode {
        case .normal: metrics.handleDiameter
        case .focused: metrics.handleDiameterFocused
        case .scrub: metrics.scrubHandleWidth
        }
    }

    @ViewBuilder
    private var handle: some View {
        switch mode {
        case .normal:
            Circle().fill(.white)
                .frame(width: metrics.handleDiameter, height: metrics.handleDiameter)
                .shadow(color: .black.opacity(0.5), radius: 2 * metrics.u, y: 1)
        case .focused:
            Circle().fill(.white)
                .frame(width: metrics.handleDiameterFocused, height: metrics.handleDiameterFocused)
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 3 * metrics.u).padding(-3 * metrics.u))
                .shadow(color: .black.opacity(0.5), radius: 2 * metrics.u, y: 1)
        case .scrub:
            RoundedRectangle(cornerRadius: 5 * metrics.u, style: .continuous).fill(.white)
                .frame(width: metrics.scrubHandleWidth, height: trackH + 22 * metrics.u)
                .shadow(color: .black.opacity(0.5), radius: 5 * metrics.u, y: 1)
        }
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

/// Attaches the iOS drag-to-seek gesture ONLY when a handler is present, so the tvOS
/// path (handlers nil, bar driven by the remote inside a focusable Button) gets no
/// gesture that could fight the focus engine. `DragGesture` is unavailable on tvOS, so
/// the whole gesture path is compiled out there — the remote drives the bar instead.
private struct ScrubGesture: ViewModifier {
    let width: CGFloat
    let onChanged: ((Double) -> Void)?
    let onEnded: ((Double) -> Void)?

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        if onChanged == nil && onEnded == nil {
            content
        } else {
            content.gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard width > 0 else { return }
                        onChanged?(min(max(v.location.x / width, 0), 1))
                    }
                    .onEnded { v in
                        guard width > 0 else { return }
                        onEnded?(min(max(v.location.x / width, 0), 1))
                    }
            )
        }
        #endif
    }
}

#Preview("normal / focused / scrub") {
    ZStack {
        LinearGradient(colors: [.purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 90) {
            PlayerProgressBar(metrics: .tv, mode: .normal, played: 0.5,
                              elapsed: "1:04:18", remaining: "-1:02:42",
                              elapsedSeconds: 3858, remainingSeconds: 3762,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89])
            PlayerProgressBar(metrics: .tv, mode: .focused, played: 0.5,
                              elapsed: "1:04:18", remaining: "-1:02:42",
                              elapsedSeconds: 3858, remainingSeconds: 3762,
                              chapters: [0.12, 0.27, 0.41, 0.58, 0.74, 0.89])
            PlayerProgressBar(metrics: .tv, mode: .scrub, played: 0.72,
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

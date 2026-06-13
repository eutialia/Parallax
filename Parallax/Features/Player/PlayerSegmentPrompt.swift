import SwiftUI
import ParallaxJellyfin

/// The contextual Skip Intro / Skip Recap / Next Episode button — a Netflix-style
/// overlay anchored bottom-trailing, just above where the scrubber's remaining-time
/// label sits, so it reads correctly whether the HUD is up or the screen is clean.
///
/// It is INDEPENDENT of the auto-hide HUD: driven purely by which segment the
/// playhead is inside (`vm.segmentPrompt`), it appears over a clean frame on segment
/// entry and runs a 3s reverse-fill countdown, then auto-hides. **One-shot**: once it
/// expires (or is dismissed) it stays suppressed for that segment until the playhead
/// leaves and re-enters (a fresh edge crossing re-arms it). The suppression id lives in
/// the parent (`PlayerView`) so the tvOS remote pipeline shares the same one-shot.
///
/// - iOS: a tappable glass capsule. Tap fires the action; the surrounding screen-tap
///   layer still toggles the HUD.
/// - tvOS: a VISUAL affordance only. The floor's `TVRemoteInputView` already holds
///   focus, so `PlayerView.send` reinterprets floor presses while this shows — Select
///   fires the action, any directional press reveals the HUD (and one-shot-dismisses
///   this). No competing focusable, so the focus engine never strands.
struct PlayerSegmentPrompt: View {
    let vm: PlayerViewModel
    /// Whether the button may show at all right now. tvOS passes `hudState == .floor`
    /// (revealing the HUD hides it); iOS passes `!scrubHUDActive` (the collapsed
    /// drag-scrub bar reads as a clean screen and owns the bottom edge).
    let enabled: Bool
    /// Shared one-shot suppression: the segment id whose prompt has already been shown
    /// (countdown elapsed, tapped, or revealed-past). Written by the countdown task,
    /// the iOS tap, and tvOS `send`; cleared when the playhead leaves all segments.
    @Binding var expiredSegmentID: String?
    /// Reports show/hide up to `PlayerView` so the tvOS `send` pipeline knows when the
    /// floor remote should act on this button instead of the transport.
    let onVisibilityChange: (Bool) -> Void
    /// Fire the active prompt (skip / next episode). Same closure tvOS `send` calls, so
    /// the action is identical across the tap and the remote.
    let onActivate: () -> Void

    /// The reverse-fill countdown length, shared by both platforms (the user unified
    /// iOS onto the tvOS 3s one-shot).
    private let countdownSeconds: Double = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drain: Double = 1

    private var currentID: String? { vm.activeSegmentID }
    private var visible: Bool {
        enabled && currentID != nil && currentID != expiredSegmentID
    }
    /// The identity the countdown + visibility callbacks key on: the shown segment, or
    /// nil when nothing should show. A new value re-arms the timer and the drain.
    private var shownKey: String? { visible ? currentID : nil }

    private var info: (icon: String, label: String, sub: String?) {
        switch vm.segmentPrompt {
        case .skip(let s): ("forward.fill", s.kind == .recap ? "Skip Recap" : "Skip Intro", nil)
        // "Up Next": name the episode we'll roll into (data already loaded with the
        // adjacency), so it's not a blind "Next Episode". Falls back when unnamed.
        case .nextEpisode: ("forward.end.fill", "Next Episode", vm.nextEpisode?.name)
        case nil: ("forward.fill", "", nil)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let m = PlayerMetrics.forSurface(geo.size)
            ZStack(alignment: .bottomTrailing) {
                // Inert — only the button hit-tests, so empty taps still reach the
                // screen-tap-to-toggle layer beneath the chrome.
                Color.clear.allowsHitTesting(false)
                if visible {
                    control(m)
                        .padding(.trailing, trailingInset(m))
                        .padding(.bottom, bottomInset(m))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.22), value: visible)
        // Arm/disarm: a new shown segment resets the drain and (re)starts it; clearing
        // resets so the next segment opens full.
        .onChange(of: shownKey, initial: true) { _, key in
            onVisibilityChange(key != nil)
            drain = 1
            if key != nil, !reduceMotion {
                withAnimation(.linear(duration: countdownSeconds)) { drain = 0 }
            }
        }
        // Leaving every segment re-arms the one-shot — a later re-entry shows again.
        .onChange(of: currentID) { _, id in
            if id == nil { expiredSegmentID = nil }
        }
        // The 3s auto-hide: suppress this segment once the countdown elapses. Keyed on
        // the shown segment, so it cancels the moment the button hides or the segment
        // changes.
        .task(id: shownKey) {
            guard shownKey != nil else { return }
            try? await Task.sleep(for: .seconds(countdownSeconds))
            guard !Task.isCancelled else { return }
            expiredSegmentID = currentID
        }
    }

    @ViewBuilder
    private func control(_ m: PlayerMetrics) -> some View {
        let button = SegmentPromptButton(icon: info.icon, label: info.label, sub: info.sub, drain: drain, metrics: m)
        #if os(tvOS)
        button   // visual only — the floor remote drives it through PlayerView.send
        #else
        // `onActivate` fires the prompt AND one-shot-dismisses it (see PlayerView).
        Button(action: onActivate) { button }
            .buttonStyle(.plain)
            .accessibilityLabel(info.sub.map { "\(info.label), \($0)" } ?? info.label)
        #endif
    }

    // MARK: Placement — pinned just above the scrubber's remaining-time label.

    private func trailingInset(_ m: PlayerMetrics) -> CGFloat {
        m.deviceClass == .phone ? PlayerMetrics.phonePadX : m.padX
    }
    private func bottomInset(_ m: PlayerMetrics) -> CGFloat {
        switch m.deviceClass {
        case .phone: PlayerMetrics.phoneProgressBottom + 58
        case .pad, .tv: m.progressBottom + 84 * m.u
        }
    }
}

/// The pure visual: a glass capsule (the shared over-video recipe) with a white-ink
/// icon + label and a reverse-fill countdown wash that drains its width to zero over
/// the prompt's lifetime. Stateless, so the `#Preview` can exercise the chrome and the
/// drain at any fraction without a live view model.
private struct SegmentPromptButton: View {
    let icon: String
    let label: String
    /// Secondary line — the next episode's name (the "Up Next" content). Dimmed and
    /// truncated so a long title can't blow the capsule out.
    var sub: String? = nil
    /// 1 = full (just appeared) … 0 = empty (about to hide). Drives the infill width.
    let drain: Double
    let metrics: PlayerMetrics

    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: iconGap) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
            Text(label)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)   // never clip the CTA
            if let sub {
                Text(sub)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Flexible up to the cap: a short title sizes to itself, a long one
                    // truncates instead of stretching the capsule across the screen.
                    .frame(maxWidth: subMaxWidth, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .frame(height: height)
        .padding(.horizontal, padX)
        // The reverse-fill: a white wash filling the capsule, its width scaled by the
        // remaining time. Behind the label, in front of the glass dim; the outer clip
        // rounds it to the capsule.
        .background(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.26))
                .scaleEffect(x: max(0, min(1, drain)), anchor: .leading)
        }
        .playerGlassSurface(in: shape)
        .clipShape(shape)
        .contentShape(shape)
    }

    private var height: CGFloat { metrics.deviceClass == .phone ? 44 : metrics.chipHeight }
    private var fontSize: CGFloat { metrics.deviceClass == .phone ? 16 : metrics.chipFontSize }
    private var iconSize: CGFloat { metrics.deviceClass == .phone ? 16 : metrics.chipIconSize }
    private var padX: CGFloat { metrics.deviceClass == .phone ? 18 : metrics.chipPadX }
    private var iconGap: CGFloat { metrics.deviceClass == .phone ? 8 : 10 * metrics.u }
    /// The "Up Next" title cap — beyond this it truncates rather than widening the pill.
    private var subMaxWidth: CGFloat { metrics.deviceClass == .phone ? 200 : 360 * metrics.u }
}

#Preview("Segment prompts") {
    ZStack {
        LinearGradient(colors: [.indigo, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: 40) {
            SegmentPromptButton(icon: "forward.fill", label: "Skip Intro", drain: 1.0, metrics: .tv)
            SegmentPromptButton(icon: "forward.fill", label: "Skip Recap", drain: 0.55, metrics: .tv)
            SegmentPromptButton(icon: "forward.end.fill", label: "Next Episode",
                                sub: "The Rains of Castamere", drain: 0.35, metrics: .tv)
            SegmentPromptButton(icon: "forward.end.fill", label: "Next Episode",
                                sub: "A Very Long Episode Title That Has To Truncate", drain: 0.2, metrics: .tv)
        }
    }
    .frame(width: 820, height: 620)
    .environment(\.colorScheme, .dark)
}

import SwiftUI

extension EnvironmentValues {
    /// Master switch for marquee looping. Previews pin it false: a running
    /// `repeatForever` never reaches quiescence, so the snapshot agent times
    /// out (`UpdateTimedOutError`) instead of rendering the truncation branch.
    @Entry var marqueeEnabled: Bool = true
}

/// Single-line text that loops horizontally when it overflows its container —
/// the Music-app now-playing treatment, for menu rows whose names can't dictate
/// the panel's width (chapter titles). Truncates statically under Reduce
/// Motion; on tvOS it runs only while the enclosing focusable row is focused
/// (the native list-row behavior), on touch it runs whenever it overflows.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    /// Intrinsic single-line width of the text, from the hidden probe.
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.marqueeEnabled) private var marqueeEnabled
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    /// Gap between the looping copies — wide enough that the restart reads as
    /// a loop, not a glitch.
    private let gap: CGFloat = 56
    private let pointsPerSecond: CGFloat = 30
    private let startDelay: TimeInterval = 1.5
    /// Soft fade at the clip edges while scrolling, so glyphs slide under a
    /// feather instead of guillotining at the frame.
    private let edgeFade: CGFloat = 12

    private var overflows: Bool { textWidth > containerWidth + 0.5 }

    private var animates: Bool {
        guard overflows, !reduceMotion, marqueeEnabled else { return false }
        #if os(tvOS)
        return isFocused
        #else
        return true
        #endif
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Intrinsic-width probe: a truncated Text reports its container's
            // width, never its own, so overflow detection needs this hidden
            // fixed-size copy. The zero frame keeps it out of layout.
            label
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                .frame(width: 0, alignment: .leading)
                .hidden()

            if animates {
                HStack(spacing: gap) {
                    label.fixedSize()
                    label.fixedSize()
                }
                .offset(x: offset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: edgeFade)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: edgeFade)
                    }
                )
            } else {
                label
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .clipped()
        .onChange(of: animates, initial: true) { _, nowAnimating in
            nowAnimating ? startScrolling() : stopScrolling()
        }
        .onChange(of: text) { _, _ in
            if animates { stopScrolling(); startScrolling() }
        }
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
    }

    /// One loop travels exactly one copy + gap, so the second copy lands where
    /// the first began and `repeatForever` reads as a seamless cycle.
    private func startScrolling() {
        let travel = textWidth + gap
        guard travel > 0 else { return }
        offset = 0
        withAnimation(
            .linear(duration: travel / pointsPerSecond)
            .delay(startDelay)
            .repeatForever(autoreverses: false)
        ) {
            offset = -travel
        }
    }

    private func stopScrolling() {
        withAnimation(.none) { offset = 0 }
    }
}

#Preview("Marquee overflow vs fit (static)", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading, spacing: 16) {
        MarqueeText(
            text: "Chapter 7: The Unexpectedly Long Title That Cannot Possibly Fit",
            font: .callout.weight(.semibold),
            color: .white
        )
        MarqueeText(text: "Short title", font: .callout.weight(.semibold), color: .white)
    }
    .frame(width: 240)
    .padding()
    .background(Color.black)
    // Snapshot-stable truncation branch (see `marqueeEnabled`).
    .environment(\.marqueeEnabled, false)
}

#Preview("Marquee live loop (canvas only)", traits: .sizeThatFitsLayout) {
    MarqueeText(
        text: "Chapter 7: The Unexpectedly Long Title That Cannot Possibly Fit",
        font: .callout.weight(.semibold),
        color: .white
    )
    .frame(width: 240)
    .padding()
    .background(Color.black)
}

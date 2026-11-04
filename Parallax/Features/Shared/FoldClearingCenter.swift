import SwiftUI
import ParallaxFeatures

/// Centers its content full-bleed and moves it clear of the fold while one divides the screen (an
/// iPhone Duo partly open; `FoldClearance` holds the rule). Full-bleed because a safe-area-bounded
/// center shifts each time the HUD toggles the status bar. The move is measured on `footprint`, not
/// the content, so views that swap in place (the play disc and the loading ring) land on the same
/// spot.
struct FoldClearingCenter<Content: View>: View {
    var footprint: CGSize
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let centered = CGRect(
                origin: CGPoint(x: (proxy.size.width - footprint.width) / 2,
                                y: (proxy.size.height - footprint.height) / 2),
                size: footprint
            )
            let shift = FoldClearance.offset(for: centered, avoiding: activeFolds(proxy))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(shift)
                .animation(reduceMotion ? nil : .organicSettle, value: shift)
        }
        .ignoresSafeArea()
    }

    private func activeFolds(_ proxy: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, tvOS 27.1, *) else { return [] }
        return proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
    }
}

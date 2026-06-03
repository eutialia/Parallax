import SwiftUI

// Liquid Glass surfaces, layered on the native material. iOS 26.5 deployment →
// `.glassEffect` is always available (no fallback). The handoff's hairline is
// added as a thin glassBorder stroke; if the native glass already reads as
// bordered enough in preview, drop the overlay.
extension View {
    /// Standard glass panel (cards, info groups). Default radius = card (18).
    func glassPanel(cornerRadius: CGFloat = Radius.card) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tint: .glass))
    }

    /// Strong glass for bars / modals. Default radius = panel (24).
    func glassBar(cornerRadius: CGFloat = Radius.panel) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tint: .glassStrong))
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .glassEffect(.regular.tint(tint), in: shape)
            .overlay(shape.strokeBorder(Color.glassBorder, lineWidth: 1))
    }
}

#Preview("Glass over artwork") {
    ZStack {
        LinearGradient(colors: [.purple, .blue, .teal],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: Space.s22) {
            Text("glassPanel")
                .padding(Space.s22)
                .glassPanel()
            Text("glassBar")
                .padding(Space.s22)
                .glassBar()
        }
        .foregroundStyle(Color.label)
        .padding(Space.s40)
    }
}

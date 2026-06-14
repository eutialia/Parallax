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

    /// Continue Watching / Next Up — TV-style footer: a frosted blur that **ramps up**
    /// toward the caption (poster stays crisp at the top edge, fully frosted at the
    /// bottom) plus a darkening scrim for legibility. Pair with
    /// `HomeShelf.footerBlurFeatherBleed`.
    func shelfTileFooterGlass() -> some View {
        background {
            // Masking a real blurring material *is* a progressive blur: clear mask
            // regions show the sharp poster, opaque regions show full frost, and the
            // alpha ramp between them is the feather. (`.glassEffect(.clear)` barely
            // blurs — that's the flat, muddy band this replaces.) Pinned dark so the
            // material resolves to its dark frosted variant over photography.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(shelfTileFooterBlurRampMask)
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(HomeShelf.footerScrimOpacity)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Frost strength increases top → bottom: the poster stays clear past the midpoint,
/// then the blur ramps in smoothly under the caption (TV shelf tiles).
private var shelfTileFooterBlurRampMask: LinearGradient {
    LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.15), location: 0.35),
            .init(color: .black.opacity(0.55), location: 0.6),
            .init(color: .black.opacity(0.9), location: 0.82),
            .init(color: .black, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
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

/// Standalone footer-blur preview tile (no `Session`/network), so the progressive
/// frost is verifiable in `RenderPreview` over a busy stand-in backdrop.
private struct ShelfFooterPreviewTile: View {
    let caption: String
    let progress: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.orange, .pink, .indigo, .green],
                           startPoint: .top, endPoint: .bottom)
                .overlay(
                    Image(systemName: "rays")
                        .resizable().scaledToFill()
                        .foregroundStyle(.white.opacity(0.35))
                )
            VStack(spacing: 0) {
                Color.clear.frame(height: HomeShelf.footerBlurFeatherBleed)
                VStack(alignment: .leading, spacing: 5) {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.28))
                            Rectangle().fill(.white).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 5)
                    .clipShape(.rect(cornerRadius: 2.5))
                }
                .padding(.horizontal, HomeShelf.footerCaptionInsetX)
                .padding(.bottom, HomeShelf.footerCaptionInsetBottom)
            }
            .frame(maxWidth: .infinity)
            .shelfTileFooterGlass()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: HomeShelf.tileWidth, height: HomeShelf.tileWidth / MediaImage.poster)
        .clipShape(.rect(cornerRadius: Radius.tile))
    }
}

#Preview("Shelf footer · progressive blur") {
    HStack(spacing: 16) {
        ShelfFooterPreviewTile(caption: "S1, E2 · 22 min left", progress: 0.4)
        ShelfFooterPreviewTile(caption: "132 min left", progress: 0.7)
    }
    .padding()
    .background(Color.background)
}

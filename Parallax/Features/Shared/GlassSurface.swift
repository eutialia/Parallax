import SwiftUI

// App-drawn surfaces are FLAT — Liquid Glass is reserved for the player + system bars (see
// DESIGN.md's material rule). This file owns the flat card (`surfacePanel`), the flat control
// fill + focus platter (`flatControlFill`), and the one remaining real-material surface: the
// shelf footer's progressive blur over poster artwork.
extension View {
    /// Flat paper-surface card — an opaque
    /// `Color.surface` fill + hairline, for cards that sit on the flat screen floor and
    /// read better solid than translucent (the detail description card, per the handoff's
    /// "paper-surface, radius 18"). Default radius = card (18).
    func surfacePanel(cornerRadius: CGFloat = Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color.surface, in: shape)
            .overlay(shape.strokeBorder(Color.separator, lineWidth: 1))
    }

    /// Flat control fill that inverts to the tvOS HIG white platter on focus. The whole
    /// non-player button system (Play pill, circle actions, form CTAs, Genre/Sort chips) is
    /// flat — Liquid Glass is reserved for the player + system bars — so this is the one place
    /// the rest-fill / focus-platter swap lives. iOS never focuses (`focused` is always false),
    /// so it's just the rest fill + hairline. The ink content on focus is the caller's job
    /// (pass `focused ? ink : rest` to `.foregroundStyle`). Pair with `tvChipButton()` for the
    /// focus lift.
    func flatControlFill<S: InsettableShape>(
        focused: Bool, rest: Color, hairline: Color? = nil, in shape: S
    ) -> some View {
        background(shape.fill(rest).opacity(focused ? 0 : 1))
            .background(shape.fill(Color.white).opacity(focused ? 1 : 0))
            .overlay {
                if let hairline {
                    shape.strokeBorder(hairline.opacity(focused ? 0 : 1), lineWidth: 1)
                }
            }
            .animation(.tvFocusChrome, value: focused)
            .contentShape(shape)
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

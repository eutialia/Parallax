import SwiftUI
import ParallaxJellyfin

struct MediaTile: View {
    @Environment(\.itemZoomNavigationValue) private var itemZoomNavigation

    let title: String
    let imageRef: ImageRef?
    let imageKind: ImageKind
    let session: Session
    let progress: Double?   // 0.0–1.0; nil hides the bar
    let progressCaption: String?
    let aspectRatio: CGFloat
    let maxImageWidth: Int

    init(
        title: String,
        imageRef: ImageRef?,
        imageKind: ImageKind,
        session: Session,
        progress: Double?,
        progressCaption: String? = nil,
        aspectRatio: CGFloat = JellyfinImage.poster,
        maxImageWidth: Int = 600
    ) {
        self.title = title
        self.imageRef = imageRef
        self.imageKind = imageKind
        self.session = session
        self.progress = progress
        self.progressCaption = progressCaption
        self.aspectRatio = aspectRatio
        self.maxImageWidth = maxImageWidth
    }

    // Poster-only tile: the title/subtitle text under the artwork was removed —
    // the poster carries identity, `title` survives solely as the VoiceOver label.
    var body: some View {
        ZStack(alignment: .bottom) {
            artwork

            if showsShelfFooterOverlay {
                shelfArtworkFooter(caption: progressCaption ?? "", progress: progress)
            }
        }
        .clipShape(.rect(cornerRadius: Radius.tile))
        // tvOS system highlight (specular + parallax) masked to the tile's own corners —
        // pairs with the `.borderless` style the enclosing button wears (`tvPosterButton`).
        .tvPosterHighlight(cornerRadius: Radius.tile)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var showsShelfFooterOverlay: Bool {
        let hasCaption = progressCaption.map { !$0.isEmpty } ?? false
        let hasProgress = (progress ?? 0) > 0
        return hasCaption || hasProgress
    }

    @ViewBuilder
    private func shelfArtworkFooter(caption: String, progress: Double?) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: HomeShelf.footerBlurFeatherBleed)
            VStack(alignment: .leading, spacing: 5) {
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let progress, progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.28))
                            Rectangle()
                                .fill(.white)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 5)
                    .clipShape(.rect(cornerRadius: 2.5))
                }
            }
            .padding(.horizontal, HomeShelf.footerCaptionInsetX)
            .padding(.bottom, HomeShelf.footerCaptionInsetBottom)
        }
        .frame(maxWidth: .infinity)
        .shelfTileFooterGlass()
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private var artwork: some View {
        let image = JellyfinImage(
            ref: imageRef,
            kind: imageKind,
            session: session,
            maxWidth: maxImageWidth,
            aspectRatio: aspectRatio
        )

        if let itemZoomNavigation {
            image.itemZoomTransitionSource(itemZoomNavigation)
        } else {
            image
        }
    }
}

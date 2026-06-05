import SwiftUI
import ParallaxJellyfin

struct MediaTile: View {
    @Environment(\.itemZoomNavigationValue) private var itemZoomNavigation

    let title: String
    let subtitle: String?
    let imageRef: ImageRef?
    let imageKind: ImageKind
    let session: Session
    let progress: Double?   // 0.0–1.0; nil hides the bar
    let progressCaption: String?
    let aspectRatio: CGFloat
    let maxImageWidth: Int
    var badges: [String]

    init(
        title: String,
        subtitle: String?,
        imageRef: ImageRef?,
        imageKind: ImageKind,
        session: Session,
        progress: Double?,
        progressCaption: String? = nil,
        aspectRatio: CGFloat = JellyfinImage.poster,
        maxImageWidth: Int = 600,
        badges: [String] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageRef = imageRef
        self.imageKind = imageKind
        self.session = session
        self.progress = progress
        self.progressCaption = progressCaption
        self.aspectRatio = aspectRatio
        self.maxImageWidth = maxImageWidth
        self.badges = badges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                artwork

                if showsShelfFooterOverlay {
                    shelfArtworkFooter(caption: progressCaption ?? "", progress: progress)
                }

                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipShape(.rect(cornerRadius: Radius.tile))
            Text(title)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Always render the subtitle line (empty when absent) and reserve
            // both lines' height so every tile is identical — otherwise mixed
            // 1-/2-line titles and present/absent subtitles make a row's (and
            // grid's) thumbnails misalign (smoke-test #6/#7).
            Text(subtitle ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .padding(.horizontal, 8)
            .padding(.bottom, 7)
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

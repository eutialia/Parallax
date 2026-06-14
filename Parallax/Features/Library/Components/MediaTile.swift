import SwiftUI
import ParallaxJellyfin
import ParallaxCore

struct MediaTile: View {
    /// Top-right corner badge state: a progress ring while a title is mid-watch,
    /// the check once it's done — one disc, the ring "fills up into" the check.
    enum WatchedStatus: Equatable {
        case none
        /// Watched fraction (0–1) — the disc's border fills clockwise.
        case inProgress(Double)
        case watched
    }

    @Environment(\.itemZoomNavigationValue) private var itemZoomNavigation

    let title: String
    let imageRef: ImageRef?
    let session: Session
    let progress: Double?   // 0.0–1.0; nil hides the bar
    let progressCaption: String?
    let watched: WatchedStatus
    let aspectRatio: CGFloat
    let maxImageWidth: Int

    init(
        title: String,
        imageRef: ImageRef?,
        session: Session,
        progress: Double?,
        progressCaption: String? = nil,
        watched: WatchedStatus = .none,
        aspectRatio: CGFloat = MediaImage.poster,
        maxImageWidth: Int = 600
    ) {
        self.title = title
        self.imageRef = imageRef
        self.session = session
        self.progress = progress
        self.progressCaption = progressCaption
        self.watched = watched
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
        // After the clip: the disc rides over the rounded corner instead of
        // being shaved by it.
        .overlay(alignment: .topTrailing) {
            statusBadge
        }
        // tvOS system highlight (specular + parallax) masked to the tile's own corners —
        // pairs with the `.borderless` style the enclosing button wears (`tvPosterButton`).
        .tvPosterHighlight(cornerRadius: Radius.tile)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(watchedAccessibilityValue)
    }

    private var watchedAccessibilityValue: String {
        switch watched {
        case .none: ""
        case .inProgress(let fraction): "\(Int((fraction * 100).rounded()))% watched"
        case .watched: "Watched"
        }
    }

    #if os(tvOS)
    private static let badgeDiameter: CGFloat = 36
    private static let badgeInset: CGFloat = 12
    private static let badgeRing: CGFloat = 3
    private static let badgeGlyph: Font = .system(size: 17, weight: .bold)
    #else
    private static let badgeDiameter: CGFloat = 22
    private static let badgeInset: CGFloat = 6
    private static let badgeRing: CGFloat = 2
    private static let badgeGlyph: Font = .system(size: 10, weight: .bold)
    #endif

    /// Watched marker — Jellyfin's top-corner check, restated quietly: a white
    /// check on a dark scrim disc, hairline-ringed so it separates from light
    /// posters without shouting over dark ones. Mid-watch, the same disc carries
    /// a progress ring on its border instead of the check — the fraction fills
    /// the border clockwise, and at 100% the full ring "becomes" the check
    /// badge. Library grids only; the continue-watching shelves carry footer
    /// progress bars instead.
    @ViewBuilder
    private var statusBadge: some View {
        switch watched {
        case .none:
            EmptyView()
        case .inProgress(let fraction):
            badgeDisc {
                Circle()
                    // Floor the arc so "just started" still reads as a ring, not a dot.
                    .trim(from: 0, to: min(max(fraction, 0.05), 1))
                    .stroke(.white, style: StrokeStyle(lineWidth: Self.badgeRing, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Center the arc on the hairline track: inset the path so the
                    // stroke straddles the disc's border instead of clipping at it.
                    .padding(Self.badgeRing / 2)
            }
        case .watched:
            badgeDisc {
                Image(systemName: "checkmark")
                    .font(Self.badgeGlyph)
                    .foregroundStyle(.white)
            }
        }
    }

    private func badgeDisc(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: Self.badgeDiameter, height: Self.badgeDiameter)
            .background(.black.opacity(0.45), in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .padding(Self.badgeInset)
            .allowsHitTesting(false)
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
        let image = MediaImage(
            jellyfin: imageRef,
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

extension MediaTile.WatchedStatus {
    /// Grid mapping from a library item: the check when played, the ring while
    /// mid-watch (movies/episodes only — a series has no single playback
    /// position, so it's check-or-nothing there).
    init(_ item: Item) {
        if item.userData.played {
            self = .watched
        } else if let fraction = item.playbackProgress, fraction > 0, fraction < 1 {
            self = .inProgress(fraction)
        } else {
            self = .none
        }
    }
}

/// Diagnostic: badge legibility on the placeholder field (the worst case is a
/// light poster — the hairline ring is what separates it there) and the
/// progress ring at the tricky fractions: barely started (floored arc), the
/// half mark, and almost-done next to the full check it morphs into.
#Preview("Watched badge", traits: .sizeThatFitsLayout) {
    let session = Session(
        persisted: PersistedSession(
            id: ServerID(rawValue: "preview"),
            serverURL: URL(string: "https://preview.invalid")!,
            serverName: "Preview",
            user: UserSnapshot(id: "u1", name: "preview", serverLastUpdatedAt: nil)
        ),
        accessToken: "preview"
    )
    return HStack(spacing: 16) {
        MediaTile(title: "Just started", imageRef: nil,
                  session: session, progress: nil, watched: .inProgress(0.02))
            .frame(width: 140)
        MediaTile(title: "Halfway", imageRef: nil,
                  session: session, progress: nil, watched: .inProgress(0.5))
            .frame(width: 140)
        MediaTile(title: "Almost done", imageRef: nil,
                  session: session, progress: nil, watched: .inProgress(0.92))
            .frame(width: 140)
        MediaTile(title: "Watched", imageRef: nil,
                  session: session, progress: nil, watched: .watched)
            .frame(width: 140)
        MediaTile(title: "Unwatched", imageRef: nil,
                  session: session, progress: nil)
            .frame(width: 140)
    }
    .padding()
    .background(Color.background)
}

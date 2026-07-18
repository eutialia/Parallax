import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The reusable artwork atom: the image box plus everything drawn *on* it — the top-right watched
/// badge and an optional bottom shelf footer (caption + progress bar over a frosted blur ramp).
///
/// Used directly by the Home / Series-detail shelves (which carry the footer) and embedded by
/// `MediaTile` (which adds a metadata row *underneath* and never shows the footer). Presentation
/// only: the caller owns the semantic accessibility — it just needs a label, since the thumbnail
/// alone isn't the whole tile when `MediaTile` wraps it.
struct MediaThumbnail: View {
    /// Top-right corner badge state: a progress ring while a title is mid-watch, the check once
    /// it's done — one disc, the ring "fills up into" the check.
    enum WatchedStatus: Equatable {
        case none
        /// Watched fraction (0–1) — the disc's border fills clockwise.
        case inProgress(Double)
        case watched
    }

    /// The bottom shelf footer (Continue Watching / Next Up / episode shelves): a caption line plus
    /// an optional progress bar, over the frosted blur ramp. Only the shelves use it; grid tiles
    /// pass nil.
    struct Footer: Equatable {
        let caption: String
        let progress: Double?   // 0.0–1.0; nil hides the bar

        // Private so `make` is the only constructor — a contentless Footer can't be built and then
        // painted as an empty ~56pt frosted band over the artwork.
        private init(caption: String, progress: Double?) {
            self.caption = caption
            self.progress = progress
        }

        /// nil when there's nothing to show (no caption and no positive progress), so an empty
        /// footer never paints its frosted band over the artwork. Callers pass the result straight
        /// to `MediaThumbnail(footer:)`.
        static func make(caption: String?, progress: Double?) -> Footer? {
            let text = caption ?? ""
            let hasProgress = (progress ?? 0) > 0
            guard !text.isEmpty || hasProgress else { return nil }
            return Footer(caption: text, progress: progress)
        }
    }

    @Environment(\.itemZoomNavigationValue) private var itemZoomNavigation

    /// The thumbnail's artwork source. Jellyfin items carry their `Session` so `MediaImage` can use
    /// the per-session auth pipeline; other sources (SMB) pass a neutral `ArtworkSource` (a local
    /// thumbnail, or `.none` for the placeholder).
    private enum Artwork {
        case jellyfin(ImageRef?, Session)
        case artwork(ArtworkSource)
    }

    private let artworkSource: Artwork
    let watched: WatchedStatus
    let footer: Footer?
    let aspectRatio: CGFloat
    let maxImageWidth: Int
    /// The point width the thumbnail renders at, when the caller knows it (fixed-width shelves).
    /// Forwarded to `MediaImage` as `renderPointWidth` so the boxed Jellyfin request trims to the
    /// panel's native pixels instead of always fetching the @3x `maxImageWidth`. nil = legacy
    /// behavior (the grid passes nil and keeps requesting `maxImageWidth`).
    let maxImageRenderWidth: CGFloat?
    /// The VoiceOver label for the thumbnail-as-element. `MediaTile` folds the metadata into this;
    /// shelves pass the title.
    let accessibilityLabel: String

    init(
        jellyfin ref: ImageRef?,
        session: Session,
        watched: WatchedStatus = .none,
        footer: Footer? = nil,
        aspectRatio: CGFloat = MediaImage.poster,
        maxImageWidth: Int = 600,
        maxImageRenderWidth: CGFloat? = nil,
        accessibilityLabel: String
    ) {
        self.artworkSource = .jellyfin(ref, session)
        self.watched = watched
        self.footer = footer
        self.aspectRatio = aspectRatio
        self.maxImageWidth = maxImageWidth
        self.maxImageRenderWidth = maxImageRenderWidth
        self.accessibilityLabel = accessibilityLabel
    }

    /// Source-neutral thumbnail for non-Jellyfin items (SMB): a local thumbnail or the placeholder,
    /// with the same badge/footer chrome as the Jellyfin path.
    init(
        artwork: ArtworkSource,
        watched: WatchedStatus = .none,
        footer: Footer? = nil,
        aspectRatio: CGFloat = MediaImage.poster,
        maxImageWidth: Int = 600,
        accessibilityLabel: String
    ) {
        self.artworkSource = .artwork(artwork)
        self.watched = watched
        self.footer = footer
        self.aspectRatio = aspectRatio
        self.maxImageWidth = maxImageWidth
        self.maxImageRenderWidth = nil
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            artwork

            if let footer {
                shelfArtworkFooter(caption: footer.caption, progress: footer.progress)
            }
        }
        .clipShape(.rect(cornerRadius: Radius.tile))
        // Seating hairline: an inner `separator` stroke so the artwork keeps a defined edge when
        // its own tone melts into the floor (dark poster on graphite, white-heavy poster on paper).
        // Inside the clip (`strokeBorder`) so it hugs the same corner geometry, and adaptive via the
        // token — ink-on-paper by day, white-on-graphite by night — the Apple TV app treatment.
        .overlay {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(Color.separator, lineWidth: 1)
        }
        // After the clip: the disc rides over the rounded corner instead of being shaved by it.
        .overlay(alignment: .topTrailing) {
            statusBadge
        }
        // tvOS system highlight (specular + parallax) masked to the tile's own corners — pairs with
        // the `.borderless` style the enclosing button wears (`tvPosterButton`).
        .tvPosterHighlight(cornerRadius: Radius.tile)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
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

    /// Watched marker — Jellyfin's top-corner check, restated quietly: a white check on a dark scrim
    /// disc, hairline-ringed so it separates from light posters without shouting over dark ones.
    /// Mid-watch, the same disc carries a progress ring on its border instead of the check — the
    /// fraction fills the border clockwise, and at 100% the full ring "becomes" the check badge.
    /// Library grids use this; the continue-watching shelves carry footer progress bars instead.
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
                    // Center the arc on the hairline track: inset the path so the stroke straddles
                    // the disc's border instead of clipping at it.
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
    private var mediaImage: some View {
        switch artworkSource {
        case .jellyfin(let ref, let session):
            MediaImage(jellyfin: ref, session: session, maxWidth: maxImageWidth, aspectRatio: aspectRatio, renderPointWidth: maxImageRenderWidth)
        case .artwork(let source):
            MediaImage(artwork: source, maxWidth: maxImageWidth, aspectRatio: aspectRatio)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let image = mediaImage

        if let itemZoomNavigation {
            image.itemZoomTransitionSource(itemZoomNavigation)
        } else {
            image
        }
    }
}

extension MediaThumbnail.WatchedStatus {
    /// Grid mapping from a library item: the check when played, the ring while mid-watch
    /// (movies/episodes only — a series has no single playback position, so it's check-or-nothing
    /// there).
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

#if DEBUG
/// The atom's two shelf footers (caption + progress, and caption-only) plus the standalone watched
/// check — the shapes the Home / Series-detail shelves render. Over the gray placeholder the
/// frosted ramp has no artwork to blur, but the scrim + caption + bar layout is verifiable here
/// without a `Session`.
#Preview("Thumbnail footer + badge", traits: .sizeThatFitsLayout) {
    HStack(spacing: 16) {
        // Explicit height boxes, like the real shelves: the footer's bottom-pinning frame is
        // vertically greedy, so a width-only frame lets the tile stretch to whatever the canvas
        // proposes (the field floor's ignoresSafeArea proposes the whole screen here).
        MediaThumbnail(
            artwork: .none,
            footer: .make(caption: "S1 E2 · 22 min left", progress: 0.4),
            aspectRatio: MediaImage.poster,
            accessibilityLabel: "Continue watching"
        )
        .frame(width: 150, height: 225)
        MediaThumbnail(
            artwork: .none,
            footer: .make(caption: "S1 E3 · 45 min", progress: nil),
            aspectRatio: MediaImage.poster,
            accessibilityLabel: "Next up"
        )
        .frame(width: 150, height: 225)
        MediaThumbnail(
            artwork: .none,
            watched: .watched,
            aspectRatio: MediaImage.landscape,
            accessibilityLabel: "Watched episode"
        )
        .frame(width: 240, height: 135)
    }
    .padding()
    // The field floor, not flat background: the gray placeholder on the paper/graphite field is
    // the tone-on-tone worst case the seating hairline exists for — this preview proves it holds.
    .screenFloor()
}
#endif

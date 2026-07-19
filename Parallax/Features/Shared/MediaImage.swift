import SwiftUI
import Nuke
import ParallaxCore
import ParallaxJellyfin

struct MediaImage: View {
    /// What the image renders from. Jellyfin keeps its per-`Session` Nuke pipeline
    /// (which carries auth at the URLSession layer) — it does NOT route through
    /// `ArtworkSource`. The neutral `artwork` case serves local/remote sources
    /// (SMB thumbnails today, headered remote reserved) over the shared pipeline.
    private enum Content {
        case jellyfin(ImageRef?, Session)
        case artwork(ArtworkSource)
    }

    private let content: Content
    private let maxWidth: Int
    /// The point width the tile actually renders at, when the caller knows it (the fixed-width
    /// shelves). Non-nil opts a boxed Jellyfin tile into display-scale-aware sizing: the server
    /// request shrinks from the @3x `maxWidth` ceiling toward `renderPointWidth × displayScale`,
    /// so a tile never decodes more pixels than its panel can show. nil = legacy behavior
    /// (request exactly `maxWidth`) — hero, logo, grid, and search keep their current requests.
    private let renderPointWidth: CGFloat?
    private let aspectRatio: CGFloat
    private let style: Style

    @Environment(\.displayScale) private var displayScale

    /// Width ÷ height — matches Jellyfin season/series/movie primary posters.
    static let poster: CGFloat = 2.0 / 3.0
    static let landscape: CGFloat = 16.0 / 9.0

    /// How the image sizes and backs its frame. One value picks the whole layout path
    /// (sizing + content mode + background) instead of inferring it from a flag combo.
    enum Style {
        /// Default: impose an `aspectRatio` box, gray placeholder, fill + crop. Grids and rows.
        case boxed
        /// Fill the caller's proposed frame edge-to-edge, gray placeholder, fill + crop. Hero
        /// bands — so `backgroundExtensionEffect` samples to the edges with no letterboxing.
        case fill
        /// Letterbox-fit over a transparent background, leading-aligned. Transparent title logos.
        case logo
    }

    init(
        jellyfin ref: ImageRef?,
        session: Session,
        maxWidth: Int,
        aspectRatio: CGFloat = MediaImage.poster,
        style: Style = .boxed,
        renderPointWidth: CGFloat? = nil
    ) {
        self.content = .jellyfin(ref, session)
        self.maxWidth = maxWidth
        self.renderPointWidth = renderPointWidth
        self.aspectRatio = aspectRatio
        self.style = style
    }

    /// Source-neutral artwork: a local file thumbnail, a headered remote URL, or none.
    /// Used by non-Jellyfin sources (SMB). `.none` shows the same gray placeholder as
    /// a missing Jellyfin poster.
    init(
        artwork: ArtworkSource,
        maxWidth: Int,
        aspectRatio: CGFloat = MediaImage.poster,
        style: Style = .boxed
    ) {
        self.content = .artwork(artwork)
        self.maxWidth = maxWidth
        self.renderPointWidth = nil
        self.aspectRatio = aspectRatio
        self.style = style
    }

    var body: some View {
        switch style {
        case .logo:
            // Transparent PNG over a backdrop: no placeholder fill, fit + leading.
            Color.clear
                .overlay(alignment: .leading) { imageOverlay }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .fill:
            // Caller owns the frame (e.g. a fixed-height hero band): fill the proposed box.
            placeholder
                .overlay { imageOverlay }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        case .boxed:
            // The cell size derives from the proposed WIDTH and the aspect ratio alone —
            // never from the loaded image's intrinsic size. Otherwise a loaded image leaks
            // its natural dimensions into layout and grid/row cells grow once the image
            // arrives, swallowing inter-item spacing. Pin the box, fill it, clip the
            // overflow — every cell stays uniform regardless of image-load state.
            placeholder
                .overlay { imageOverlay }
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipped()
        }
    }

    /// The fill drawn BEHIND the loaded artwork — it pins the cell's box while the real image
    /// streams in, then the loaded image fades in on top (network/disk loads ease in over 0.25s;
    /// memory-cache hits appear instantly — see `ArtworkFadeIn`). For Jellyfin content that carries a
    /// BlurHash we decode it into a blurred impression of the incoming poster (a soft colour field
    /// that matches the artwork) instead of a flat gray box; everything else — SMB/local artwork, or a
    /// Jellyfin ref with no hash — keeps the flat `Color.artworkPlaceholder`. Only reached by `.fill`
    /// and `.boxed`; `.logo` deliberately draws no placeholder (transparent PNGs sit over artwork).
    @ViewBuilder
    private var placeholder: some View {
        if case .jellyfin(let ref, _) = content, let hash = ref?.blurHash {
            // `aspectRatio` picks the decode raster's shape only — BlurHashPlaceholder is
            // layout-neutral by construction (see its doc), so this cannot feed back into sizing.
            BlurHashPlaceholder(hash: hash, aspectRatio: aspectRatio)
        } else {
            Color.artworkPlaceholder
        }
    }

    /// The exact (maxWidth, maxHeight) to request, from the SAME `ArtworkRequest.boxedSize` the
    /// prefetcher uses — one source for the box, so a tile and a warm-up prefetch always resolve the
    /// identical URL (no drift = no double-download). A boxed tile trims toward native pixels when a
    /// render width is known and otherwise keeps the @3x `maxWidth` ceiling; fill/logo keep the raw
    /// ceiling and no height bound (the layout, not the scaler, sizes them).
    private var requestBox: (width: Int, height: Int?) {
        guard style == .boxed else { return (maxWidth, nil) }
        let size = ArtworkRequest.boxedSize(
            ceiling: maxWidth,
            renderPointWidth: renderPointWidth,
            displayScale: displayScale,
            aspectRatio: aspectRatio
        )
        return (size.width, size.height)
    }

    @ViewBuilder
    private var imageOverlay: some View {
        switch content {
        case .jellyfin(let ref, let session):
            jellyfinOverlay(ref: ref, session: session)
        case .artwork(let source):
            artworkOverlay(source)
        }
    }

    @ViewBuilder
    private func jellyfinOverlay(ref: ImageRef?, session: Session) -> some View {
        if let ref, let url = ImageURLBuilder.url(
            serverURL: session.serverURL,
            ref: ref,
            maxWidth: requestBox.width,
            maxHeight: requestBox.height
        ) {
            let renderer = LazyImageRenderer(
                url: url,
                session: session,
                contentMode: style == .logo ? .fit : .fill
            )
            // Logo titles must stay leading-aligned; an infinite frame makes `.fit` letterbox
            // inside the full column width and reads as centered. Fill/boxed need it to cover cells.
            switch style {
            case .logo: renderer
            case .fill, .boxed: renderer.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func artworkOverlay(_ source: ArtworkSource) -> some View {
        switch source {
        case .none:
            // Placeholder already sits behind the overlay — nothing to draw.
            EmptyView()
        case .local(let url):
            artworkImage(ImageRequest(url: url))
        case .remote(let url, let headers):
            artworkImage(remoteRequest(url: url, headers: headers))
        }
    }

    /// Renders a non-Jellyfin image over the shared (default) Nuke pipeline — no
    /// per-session auth. Mirrors `LazyImageRenderer`'s presentation (resizable +
    /// aspect-fill/fit + the same frame treatment per style).
    ///
    /// `allowsHitTesting(false)`: the artwork is purely decorative — the enclosing control (the SMB
    /// grid `Button`) owns the tap. A `.fill` thumbnail with a wider aspect than its box (a 16:9
    /// video frame in a 2:3 poster cell) overflows horizontally; left interactive, that overflow
    /// steals taps from the `Button` and from neighbouring cells (only the last-drawn tile in a row
    /// stayed tappable). The placeholder behind it still provides the cell's hit region.
    @ViewBuilder
    private func artworkImage(_ request: ImageRequest) -> some View {
        let image = LazyImage(request: request) { state in
            if let image = state.image {
                image.resizable()
                    .aspectRatio(contentMode: style == .logo ? .fit : .fill)
                    .accessibilityIgnoresInvertColors()
                    .artworkFadeIn(isMemoryHit: state.isArtworkMemoryHit)
            }
        }
        switch style {
        case .logo: image.allowsHitTesting(false)
        case .fill, .boxed: image.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
        }
    }

    private func remoteRequest(url: URL, headers: [String: String]?) -> ImageRequest {
        guard let headers, !headers.isEmpty else { return ImageRequest(url: url) }
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return ImageRequest(urlRequest: request)
    }
}

/// Sizing for Jellyfin artwork requests, shared by `MediaImage` (the on-screen tile) and
/// `ArtworkPrefetcher` so both resolve the SAME server URL — a prefetch warms the exact cache
/// entry the tile then reads, instead of a different size that double-downloads.
enum ArtworkRequest {
    /// Headroom for the tvOS focus lift: a focused poster scales ~1.1 (a render-only transform that
    /// doesn't grow the layout box), so a layout-derived width must reserve a little extra to stay
    /// crisp while lifted. Harmless on iOS (no lift) — it's capped by the ceiling either way.
    private static let focusLiftHeadroom: CGFloat = 1.15

    /// Pixel width to request for artwork drawn at `pointWidth`: `pointWidth × displayScale` (the
    /// framebuffer can't show more) plus the lift headroom, CAPPED at `ceiling` (the legacy @3x
    /// token). It can only REDUCE over-fetch — @3x iPhone stays at the ceiling (byte-identical),
    /// lower-scale displays (tvOS / iPad @2x) trim toward native size — and never undersizes below
    /// what's drawn, so there is no visual change on any platform.
    static func width(pointWidth: CGFloat, displayScale: CGFloat, ceiling: Int) -> Int {
        guard pointWidth > 0, displayScale > 0 else { return ceiling }
        return min(ceiling, Int((pointWidth * displayScale * focusLiftHeadroom).rounded(.up)))
    }

    /// The (maxWidth, maxHeight) a `.boxed` Jellyfin tile requests — width via `width(...)`, height
    /// from the aspect ratio (mirrors `MediaImage.requestMaxWidth`/`requestMaxHeight`). The
    /// prefetcher builds its URL from this so the keys match.
    static func boxedSize(
        ceiling: Int, renderPointWidth: CGFloat?, displayScale: CGFloat, aspectRatio: CGFloat
    ) -> (width: Int, height: Int) {
        let w = renderPointWidth.map {
            width(pointWidth: $0, displayScale: displayScale, ceiling: ceiling)
        } ?? ceiling
        return (w, Int((Double(w) / aspectRatio).rounded()))
    }
}

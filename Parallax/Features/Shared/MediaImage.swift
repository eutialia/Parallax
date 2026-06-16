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
    private let aspectRatio: CGFloat
    private let style: Style

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
        style: Style = .boxed
    ) {
        self.content = .jellyfin(ref, session)
        self.maxWidth = maxWidth
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

    private var placeholder: Color { Color(white: 0.15) }

    /// When the layout box is poster-shaped, ask the source for a matching height so
    /// the scaler doesn't squeeze width-only thumbs into a tall cell.
    private var requestMaxHeight: Int? {
        guard style == .boxed else { return nil }
        return Int((Double(maxWidth) / aspectRatio).rounded())
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
            maxWidth: maxWidth,
            maxHeight: requestMaxHeight
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

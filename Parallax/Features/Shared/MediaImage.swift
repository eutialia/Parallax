import SwiftUI
import Nuke
import ParallaxCore
import ParallaxJellyfin

struct MediaImage: View {
    private let ref: ImageRef?
    private let session: Session
    private let maxWidth: Int
    private let aspectRatio: CGFloat
    private let style: Style

    /// Width ÷ height — matches Jellyfin season/series/movie primary posters.
    static let poster: CGFloat = 2.0 / 3.0
    static let landscape: CGFloat = 16.0 / 9.0
    static let banner: CGFloat = 1000.0 / 185.0

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
        aspectRatio: CGFloat = 2.0 / 3.0,
        style: Style = .boxed
    ) {
        self.ref = ref
        self.session = session
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

    /// When the layout box is poster-shaped, ask Jellyfin for a matching height so
    /// the scaler doesn't squeeze width-only thumbs into a tall cell.
    private var requestMaxHeight: Int? {
        guard style == .boxed else { return nil }
        return Int((Double(maxWidth) / aspectRatio).rounded())
    }

    @ViewBuilder
    private var imageOverlay: some View {
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
}

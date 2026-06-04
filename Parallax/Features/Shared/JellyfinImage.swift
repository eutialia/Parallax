import SwiftUI
import Nuke
import ParallaxJellyfin

struct JellyfinImage: View {
    let ref: ImageRef?
    let kind: ImageKind
    let session: Session
    let maxWidth: Int
    let aspectRatio: CGFloat
    let style: Style

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
        ref: ImageRef?,
        kind: ImageKind,
        session: Session,
        maxWidth: Int,
        aspectRatio: CGFloat = 2.0 / 3.0,
        style: Style = .boxed
    ) {
        self.ref = ref
        self.kind = kind
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

    @ViewBuilder
    private var imageOverlay: some View {
        if let ref, let url = ImageURLBuilder.url(serverURL: session.serverURL, ref: ref, maxWidth: maxWidth) {
            LazyImageRenderer(url: url, session: session, contentMode: style == .logo ? .fit : .fill)
        }
    }
}

// Separate child view so the pipeline lookup happens inside a body
// with a stable identity, avoiding repeated actor hops on every outer
// parent redraw.
private struct LazyImageRenderer: View {
    let url: URL
    let session: Session
    var contentMode: ContentMode = .fill

    @Environment(AppDependencies.self) private var deps
    @State private var pipeline: ImagePipeline?

    var body: some View {
        Group {
            if let pipeline {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: contentMode)
                    }
                }
                .pipeline(pipeline)
            } else {
                Color.clear
            }
        }
        // Key on the whole session, not just session.id: when the user signs
        // out and back into the SAME server the ServerID is unchanged but the
        // access token rotates. Keying on session.id alone would keep serving
        // the stale pipeline (401s). Session is Hashable over its token, so
        // this refires on rotation; switching the pipeline also makes NukeUI
        // cancel the in-flight tasks bound to the old (stale-token) pipeline.
        .task(id: session) {
            pipeline = await deps.imagePipelineFactory.pipeline(for: session)
        }
    }
}

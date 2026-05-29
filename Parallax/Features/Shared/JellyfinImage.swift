import SwiftUI
import Nuke
import ParallaxJellyfin

struct JellyfinImage: View {
    let ref: ImageRef?
    let kind: ImageKind
    let session: Session
    let maxWidth: Int
    let aspectRatio: CGFloat

    static let poster: CGFloat = 2.0 / 3.0
    static let landscape: CGFloat = 16.0 / 9.0
    static let banner: CGFloat = 1000.0 / 185.0

    init(
        ref: ImageRef?,
        kind: ImageKind,
        session: Session,
        maxWidth: Int,
        aspectRatio: CGFloat = 2.0 / 3.0
    ) {
        self.ref = ref
        self.kind = kind
        self.session = session
        self.maxWidth = maxWidth
        self.aspectRatio = aspectRatio
    }

    var body: some View {
        // The cell size derives from the proposed WIDTH and the aspect ratio
        // alone — never from the loaded image's intrinsic size. The old
        // `.aspectRatio(.fill)` over a flexible ZStack let a loaded image leak
        // its natural dimensions into layout: grid/row cells grew row-to-row
        // once the image arrived and overflowed their column, swallowing the
        // inter-item spacing (device smoke-test #6/#7). Pin the box first, then
        // fill it with the image and clip the overflow — every cell stays
        // uniform regardless of image-load state.
        Color(white: 0.15)
            .overlay {
                if let ref, let url = ImageURLBuilder.url(serverURL: session.serverURL, ref: ref, maxWidth: maxWidth) {
                    LazyImageRenderer(url: url, session: session)
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipped()
    }
}

// Separate child view so the pipeline lookup happens inside a body
// with a stable identity, avoiding repeated actor hops on every outer
// parent redraw.
private struct LazyImageRenderer: View {
    let url: URL
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var pipeline: ImagePipeline?

    var body: some View {
        Group {
            if let pipeline {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
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

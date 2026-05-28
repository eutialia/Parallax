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
        ZStack {
            placeholder
            if let ref, let url = ImageURLBuilder.url(serverURL: session.serverURL, ref: ref, maxWidth: maxWidth) {
                LazyImageRenderer(url: url, session: session)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fill)
        .clipped()
    }

    @ViewBuilder
    private var placeholder: some View {
        Rectangle()
            .fill(Color(white: 0.15))
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
        .task(id: session.id) {
            pipeline = await deps.imagePipelineFactory.pipeline(for: session)
        }
    }
}

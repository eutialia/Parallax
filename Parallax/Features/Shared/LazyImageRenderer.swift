import SwiftUI
import Nuke
import ParallaxJellyfin

/// Loads a raw image URL through the per-`Session` Nuke pipeline. Split out as its own
/// view so the pipeline lookup happens inside a body with a stable identity, avoiding
/// repeated actor hops on every outer parent redraw. Used by `MediaImage` for item art
/// that needs the session-scoped pipeline — this is the one place that resolves it.
struct LazyImageRenderer: View {
    let url: URL
    let session: Session
    var contentMode: ContentMode = .fill
    /// Pipeline-level processors (e.g. the logo alpha-trim). Part of Nuke's cache key via each
    /// processor's `identifier`, so processed variants cache independently of the original.
    var processors: [any ImageProcessing] = []

    @Environment(AppDependencies.self) private var deps
    @State private var pipeline: ImagePipeline?

    var body: some View {
        Group {
            if let pipeline {
                LazyImage(request: ImageRequest(url: url, processors: processors)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: contentMode)
                            .accessibilityIgnoresInvertColors()
                            .artworkFadeIn(isMemoryHit: state.isArtworkMemoryHit)
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

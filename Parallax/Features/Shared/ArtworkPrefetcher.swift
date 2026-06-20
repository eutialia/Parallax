import SwiftUI
import Nuke
import ParallaxJellyfin

extension View {
    /// Warm the per-session Nuke cache for a set of artwork URLs while this view is on screen, so a
    /// tile that scrolls into a lazy shelf is already decoded by the time it appears — the companion
    /// to the `LazyHStack` shelves (which otherwise decode on demand as focus reaches each tile).
    ///
    /// The URLs MUST be built with `ArtworkRequest` (the same sizing the tiles use), or the prefetch
    /// warms a different cache key and just double-downloads. Prefetching is best-effort and bounded
    /// to the shelf's own items (a short list), so it can't flood the cache; it stops when the view
    /// leaves the screen or the URL set changes.
    func prefetchArtwork(_ urls: [URL], session: Session) -> some View {
        modifier(ArtworkPrefetchModifier(urls: urls, session: session))
    }
}

private struct ArtworkPrefetchModifier: ViewModifier {
    let urls: [URL]
    let session: Session

    @Environment(AppDependencies.self) private var deps
    @State private var prefetcher: ImagePrefetcher?

    func body(content: Content) -> some View {
        content
            // Keyed on (session, urls) so the task re-runs — re-resolving the pipeline (the factory
            // caches it, so this is cheap) and restarting on the fresh set — whenever either changes.
            // Keying on the full set, not a count, means a refresh that swaps items in place still
            // re-warms. The captured `urls` are therefore always current (no stale-capture race).
            .task(id: PrefetchKey(session: session, urls: urls)) {
                guard !urls.isEmpty else { return }
                let pipeline = await deps.imagePipelineFactory.pipeline(for: session)
                // The await is a suspension point: if the view left the screen or the URL set changed
                // while the pipeline resolved, this task was cancelled. Bail before starting — past
                // this point `onDisappear`/the superseding task can no longer stop us, so we'd leak a
                // prefetcher churning a dead set.
                guard !Task.isCancelled else { return }
                prefetcher?.stopPrefetching()
                let next = ImagePrefetcher(pipeline: pipeline)
                next.startPrefetching(with: urls)
                prefetcher = next
            }
            .onDisappear { prefetcher?.stopPrefetching() }
    }

    private struct PrefetchKey: Equatable {
        let session: Session
        let urls: [URL]
    }
}

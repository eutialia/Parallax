import SwiftUI
import Nuke
import ParallaxCore
import ParallaxJellyfin

/// The one place a shelf's warm-up URL set is built, so the on-screen tile and its prefetch always
/// resolve the IDENTICAL server URL (any drift warms a different cache key and just double-downloads).
enum ArtworkPrefetch {
    /// The exact artwork URLs a set of shelf tiles will request. Pass the tiles' `serverURL`, the same
    /// `ceiling` / `renderPointWidth` / `displayScale` / `aspectRatio` the tile feeds `MediaImage`, and
    /// a per-item `imageRef` mapping (the SAME ref the tile draws — nil refs drop out). Built through
    /// `ArtworkRequest.boxedSize` + `ImageURLBuilder.url`, the tile's own sizing path.
    static func urls<Element>(
        for items: [Element],
        imageRef: (Element) -> ImageRef?,
        serverURL: URL,
        ceiling: Int,
        renderPointWidth: CGFloat,
        displayScale: CGFloat,
        aspectRatio: CGFloat
    ) -> [URL] {
        let size = ArtworkRequest.boxedSize(
            ceiling: ceiling,
            renderPointWidth: renderPointWidth,
            displayScale: displayScale,
            aspectRatio: aspectRatio
        )
        return items.compactMap { element in
            imageRef(element).flatMap {
                ImageURLBuilder.url(serverURL: serverURL, ref: $0, maxWidth: size.width, maxHeight: size.height)
            }
        }
    }
}

/// One server's share of a mixed shelf's warm-up: its own session (which selects the Nuke pipeline
/// carrying that server's auth) and the URLs built against that server's host.
struct ArtworkPrefetchGroup: Equatable {
    let session: Session
    let urls: [URL]
}

extension ArtworkPrefetch {
    /// Warm-up groups for a shelf whose items come from SEVERAL servers. Artwork URLs and the Nuke
    /// pipeline are both per-server (host + bearer token), so a mixed shelf can't be warmed with one
    /// server URL — the items are bucketed by their own session first, in first-appearance order so
    /// the result is stable across renders.
    static func groups<Element>(
        for items: [Element],
        session: (Element) -> Session?,
        imageRef: (Element) -> ImageRef?,
        ceiling: Int,
        renderPointWidth: CGFloat,
        displayScale: CGFloat,
        aspectRatio: CGFloat
    ) -> [ArtworkPrefetchGroup] {
        var order: [ServerID] = []
        var buckets: [ServerID: (session: Session, items: [Element])] = [:]
        for item in items {
            guard let session = session(item) else { continue }
            if buckets[session.id] == nil {
                order.append(session.id)
                buckets[session.id] = (session, [])
            }
            buckets[session.id]?.items.append(item)
        }
        return order.compactMap { id in
            guard let bucket = buckets[id] else { return nil }
            let urls = urls(
                for: bucket.items,
                imageRef: imageRef,
                serverURL: bucket.session.serverURL,
                ceiling: ceiling,
                renderPointWidth: renderPointWidth,
                displayScale: displayScale,
                aspectRatio: aspectRatio
            )
            return urls.isEmpty ? nil : ArtworkPrefetchGroup(session: bucket.session, urls: urls)
        }
    }
}

extension View {
    /// Warm the caches for a shelf whose tiles come from several servers — one prefetcher per
    /// server, since each has its own pipeline and its own URLs. Same lifecycle contract as the
    /// single-session `prefetchArtwork`: bounded to the shelf's items, stopped when the view leaves
    /// or the set changes.
    func prefetchArtwork(groups: [ArtworkPrefetchGroup]) -> some View {
        modifier(SourcedArtworkPrefetchModifier(groups: groups))
    }

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

/// Multi-server variant: resolves each group's pipeline and runs one prefetcher per server. Kept as
/// its own modifier rather than N stacked single-session ones, because the group count is dynamic
/// (it follows how many servers happen to appear in the shelf) and modifiers can't be applied
/// dynamically.
private struct SourcedArtworkPrefetchModifier: ViewModifier {
    let groups: [ArtworkPrefetchGroup]

    @Environment(AppDependencies.self) private var deps
    @State private var prefetchers: [ImagePrefetcher] = []

    func body(content: Content) -> some View {
        content
            // Keyed on the whole group set so a refresh that swaps items in place still re-warms,
            // and a server appearing/disappearing from the shelf restarts cleanly.
            .task(id: groups) {
                guard !groups.isEmpty else { return }
                var resolved: [(pipeline: ImagePipeline, urls: [URL])] = []
                for group in groups {
                    let pipeline = await deps.imagePipelineFactory.pipeline(for: group.session)
                    // Each await is a suspension point: if the view left or the set changed while a
                    // pipeline resolved, bail before starting anything — past the start call the
                    // superseding task can no longer stop these.
                    guard !Task.isCancelled else { return }
                    resolved.append((pipeline, group.urls))
                }
                stop()
                prefetchers = resolved.map { entry in
                    let prefetcher = ImagePrefetcher(pipeline: entry.pipeline)
                    prefetcher.startPrefetching(with: entry.urls)
                    return prefetcher
                }
            }
            .onDisappear(perform: stop)
    }

    private func stop() {
        for prefetcher in prefetchers { prefetcher.stopPrefetching() }
    }
}

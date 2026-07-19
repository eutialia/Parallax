import SwiftUI
import Nuke
import ParallaxJellyfin

/// Fades freshly-fetched artwork in over its BlurHash/gray placeholder — but only when the image
/// actually had to load. Network and disk-cache loads ease in over 0.25s (the placeholder shows
/// through until the poster lands); memory-cache hits — an image NukeUI hands back synchronously,
/// e.g. scrolling a tile back on-screen — appear instantly, because fading an already-cached image
/// reads as a broken, laggy scroll. Pure opacity: no scale or movement, so it stays put under
/// Reduce Motion (non-vestibular, kept by convention) and never touches the focus tree on tvOS —
/// the tile is already focusable; only its image content cross-fades.
private struct ArtworkFadeIn: ViewModifier {
    let isMemoryHit: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            // A memory hit is opaque from the first frame it renders (before `onAppear` even runs),
            // so there is no placeholder flash; everything else starts hidden and eases up.
            .opacity(shown || isMemoryHit ? 1 : 0)
            .onAppear {
                guard !isMemoryHit else { return }
                withAnimation(.artworkReveal) { shown = true }
            }
    }
}

extension View {
    /// Applies the shared artwork fade-in (see `ArtworkFadeIn`). Drive `isMemoryHit` from
    /// `LazyImageState.isArtworkMemoryHit` at the point the image resolves inside a `LazyImage`
    /// content closure.
    func artworkFadeIn(isMemoryHit: Bool) -> some View {
        modifier(ArtworkFadeIn(isMemoryHit: isMemoryHit))
    }
}

extension LazyImageState {
    /// True when NukeUI served this image straight from the in-memory cache — delivered
    /// synchronously on the first `load()` (`FetchImage`'s quick memory lookup tags the response
    /// `.memory`). Network fetches report `nil` and disk-cache reads report `.disk`; both count as
    /// "not a memory hit" and get the fade.
    var isArtworkMemoryHit: Bool {
        guard case .success(let response) = result else { return false }
        if case .memory = response.cacheType { return true }
        return false
    }
}

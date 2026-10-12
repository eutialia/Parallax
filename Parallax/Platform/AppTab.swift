import ParallaxFeatures

enum AppTab: Hashable {
    case home, library, search, settings
    case collection(LibraryRef)
    /// The cross-library Favorites grid — a virtual library, not a server collection.
    case favorites

    /// Fall back to `.home` if this tab points at a library collection no longer present in `entries`
    /// — the stale-tab snap both platform roots (`RootTabView`, `FocusRootView`) run whenever the
    /// library list changes. Shared so the two roots can't drift.
    func snappedIfStale(against entries: [LibraryEntry]) -> AppTab {
        if case .collection(let ref) = self, !entries.contains(where: { $0.id == ref }) {
            return .home
        }
        return self
    }
}

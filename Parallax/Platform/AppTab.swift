import ParallaxJellyfin
import ParallaxCore

enum AppTab: Hashable {
    case home, library, search, settings
    case collection(CollectionID)
    /// The cross-library Favorites grid — a virtual library, not a server collection.
    case favorites
}

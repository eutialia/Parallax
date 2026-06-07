import ParallaxJellyfin

enum AppTab: Hashable {
    case home, library, search
    case collection(CollectionID)
}
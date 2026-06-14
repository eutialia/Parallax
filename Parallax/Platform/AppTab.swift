// No package imports: the only non-stdlib associated value is LibraryRef, which is app-local.
enum AppTab: Hashable {
    case home, library, search, settings
    case collection(LibraryRef)
    /// The cross-library Favorites grid — a virtual library, not a server collection.
    case favorites
}

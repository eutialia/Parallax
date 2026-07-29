import SwiftUI

extension View {
    /// Paint the tvOS screen floor under the logged-out Connect `NavigationStack`, which mounts
    /// outside `RootView`'s tab host and the single floor it paints there (each pushed page's
    /// scaffold paints none on tvOS, so the surface must survive nav pushes from below). There is
    /// NO custom heading chrome — signed-in surfaces get their identity from the native
    /// `.sidebarAdaptable` pill, and Connect's forms carry their own headers. No-op on iOS/iPadOS,
    /// where `SettingsScaffold` paints the surface per page.
    @ViewBuilder
    func tvSettingsFloor() -> some View {
        #if os(tvOS)
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .screenFloor()
        #else
        self
        #endif
    }
}

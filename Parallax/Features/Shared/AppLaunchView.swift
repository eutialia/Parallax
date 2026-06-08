import SwiftUI

/// Full-screen launch surface shown while the app loads its first screen's data.
///
/// On tvOS this is the gate that keeps the `.sidebarAdaptable` menu off-screen during the
/// cold-launch fetch: the UIKit-backed sidebar can't claim (and hold, expanded) focus if it
/// isn't on screen yet. The root reveals the real UI only once the content is ready and the
/// hero is focusable from the first frame, so the sidebar hands focus straight to the content.
///
/// Deliberately minimal and self-contained so a richer launch *animation* can replace the
/// spinner later without touching the gate logic — swap the body, keep the surface.
struct AppLaunchView: View {
    var body: some View {
        Color.background
            .ignoresSafeArea()
            .overlay { ProgressView().controlSize(.large) }
    }
}

#Preview {
    AppLaunchView()
}

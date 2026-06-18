#if !os(tvOS)
import UIKit

/// Single source of truth for the app's allowed interface orientations.
///
/// SwiftUI's lifecycle app has an auto-generated scene with no `SceneDelegate`, so the
/// only hook UIKit exposes for orientation is the app delegate's
/// `application(_:supportedInterfaceOrientationsFor:)` (see `OrientationAppDelegate`). That
/// method reads `mask` here; flipping `mask` and asking the scene for a geometry update is
/// what forces a rotation.
///
/// Parallax doesn't offer portrait video, so the iPhone player locks to landscape while
/// it's on screen and restores the browse default when it leaves. iPad is never locked —
/// its canvas is fine in any orientation — so the lock calls are no-ops there.
@MainActor
final class OrientationController {
    static let shared = OrientationController()
    private init() {}

    /// The browse default, matching the Info.plist `UISupportedInterfaceOrientations`:
    /// every orientation on iPad, all-but-upside-down on iPhone (devices without a Home
    /// button don't support upside-down).
    private var browseDefault: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// What the app delegate reports to UIKit. Starts at the browse default; the player
    /// narrows it to landscape on iPhone.
    private(set) lazy var mask: UIInterfaceOrientationMask = browseDefault

    /// Lock iPhone playback to landscape and rotate there now. No-op on iPad.
    func lockLandscapeForPlayer() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        apply(.landscape, rotateTo: .landscape)
    }

    /// Drop the player's lock back to the browse default, letting the live device
    /// orientation settle the browse UI again. No-op on iPad (never locked).
    func releasePlayerLock() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        apply(browseDefault, rotateTo: nil)
    }

    /// Update the reported mask, then nudge UIKit to act on it: an explicit geometry
    /// request when we want to FORCE an orientation (the lock), and a re-query of the
    /// root controller's supported orientations either way so the change takes effect
    /// (the release leans on this to follow the device back).
    private func apply(_ newMask: UIInterfaceOrientationMask, rotateTo rotation: UIInterfaceOrientationMask?) {
        mask = newMask
        guard let scene = activeWindowScene else { return }
        if let rotation {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotation))
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// Exists solely to vend `OrientationController`'s mask to UIKit — the one orientation
/// hook a SwiftUI lifecycle app can reach. Wired via `@UIApplicationDelegateAdaptor` in
/// `ParallaxApp` (iOS only).
@MainActor
final class OrientationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.shared.mask
    }
}
#endif

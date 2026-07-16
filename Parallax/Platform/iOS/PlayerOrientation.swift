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
/// Parallax doesn't offer portrait video, so the iPhone has exactly two orientation
/// states — browse is portrait-only, the player is landscape-only (the Netflix shape) —
/// and every transition between them is a FORCED rotation, never "follow the device".
/// Exclusive masks are what make the hand-offs deterministic: releasing the player's
/// lock rotates back to portrait even when the phone was already physically portrait
/// throughout playback (with landscape still allowed at rest, UIKit saw no reason to
/// rotate and the browse UI stayed stuck sideways until a scene re-activation).
/// iPad is never locked — its canvas is fine in any orientation — so both calls are
/// no-ops there.
@MainActor
final class OrientationController {
    static let shared = OrientationController()
    private init() {}

    /// The at-rest orientations: every orientation on iPad, portrait-only on iPhone.
    /// Narrower than the Info.plist `UISupportedInterfaceOrientations_iPhone` on
    /// purpose — the plist must keep the landscape pair or the player could never
    /// rotate there; this delegate-reported mask is what confines browse.
    private var browseDefault: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    /// What the app delegate reports to UIKit. Starts at the browse default; the player
    /// swaps it for landscape on iPhone.
    private(set) lazy var mask: UIInterfaceOrientationMask = browseDefault

    /// Lock iPhone playback to landscape and rotate there now. No-op on iPad.
    func lockLandscapeForPlayer() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        apply(.landscape)
    }

    /// Restore the portrait-only browse mask and rotate back now. No-op on iPad
    /// (never locked).
    func releasePlayerLock() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        apply(browseDefault)
    }

    /// One in-flight settle check per `apply` — a lock/release landing while the
    /// previous check sleeps supersedes it.
    private var settleTask: Task<Void, Never>?

    /// Update the reported mask, force UIKit onto it, and arm the one-shot settle
    /// check. The check is armed even when no scene was reachable for the rotation
    /// itself (launch/reconnection edges): 600ms later a scene usually exists, and
    /// the verify pass is the only path that would ever notice the missed rotation.
    private func apply(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        forceRotation(to: newMask)
        verifySettled(on: newMask)
    }

    /// The two UIKit calls that turn the vended mask into an actual rotation.
    /// Invalidate BEFORE requesting: the geometry request is validated against the
    /// scene's CACHED resolved orientations, and with exclusive masks the stale cache
    /// never contains the requested orientation — requested-after-invalidated is the
    /// difference between rotating and a silent UISceneErrorDomain 101 rejection
    /// (sim-reproduced; the player mounted in portrait).
    private func forceRotation(to newMask: UIInterfaceOrientationMask) {
        guard let scene = activeWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask))
    }

    /// The self-heal for a dropped geometry request — e.g. one that landed while
    /// another rotation was in flight: after the rotation animation had time to land,
    /// re-issue the UIKit calls once if the scene's orientation still isn't in the
    /// mask. Bounded to one retry structurally (the retry never re-verifies), so a
    /// genuinely wedged scene can't loop — and a wedge is transient anyway: UIKit
    /// re-queries the delegate mask on the next scene activation, and the exclusive
    /// mask corrects the orientation then.
    private func verifySettled(on newMask: UIInterfaceOrientationMask) {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, mask == newMask,
                  let scene = activeWindowScene else { return }
            let current = scene.effectiveGeometry.interfaceOrientation
            // Mask bits are defined as `1 << orientation.rawValue` (UIApplication.h).
            guard current != .unknown,
                  !newMask.contains(UIInterfaceOrientationMask(rawValue: 1 << current.rawValue))
            else { return }
            forceRotation(to: newMask)
        }
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

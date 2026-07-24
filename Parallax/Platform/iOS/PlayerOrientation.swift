#if !os(tvOS)
import UIKit

/// Single source of truth for the app's allowed interface orientations.
///
/// SwiftUI's lifecycle app has an auto-generated scene with no `SceneDelegate`, so the
/// only hook UIKit exposes for orientation is the app delegate's
/// `application(_:supportedInterfaceOrientationsFor:)` (see `OrientationAppDelegate`). That
/// method reads `mask` here; widening `mask` lets UIKit follow the device, and a geometry
/// request forces a specific side.
///
/// The iPhone player FOLLOWS THE DEVICE (v2): browse is portrait-only, but presenting the
/// player widens the mask to portrait+landscape so the physical orientation drives the
/// rotation — hold the phone sideways and it goes landscape on its own, hold it upright and
/// it stays portrait. The rotate button (`rotatePlayer(to:)`) forces a side on top of that,
/// overriding even the system rotation lock. DISMISS narrows back to the EXCLUSIVE portrait
/// browse mask and force-rotates there: a permissive rest mask left the browse UI stuck
/// sideways after a landscape session (UIKit saw no reason to rotate), so the exclusive
/// narrow-then-force hand-off stays. iPad is never orientation-managed — its canvas is fine
/// any way up — so every call is a no-op there.
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

    /// Player PRESENT (iPhone only): widen the reported mask to portrait+landscape (the
    /// plist set, minus upside-down) and invalidate so UIKit re-queries it. NO geometry
    /// request — the device's physical orientation drives the rotation from here; if the
    /// user is already holding landscape, UIKit rotates the moment the mask widens.
    /// No-op on iPad (never managed).
    func beginPlayerPresentation() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        mask = [.portrait, .landscape]
        invalidateSupportedOrientations()
    }

    /// Player DISMISS (iPhone only): restore the EXCLUSIVE portrait browse mask and force
    /// the rotation back now (the full `apply` — invalidate → request → verify). The rest
    /// mask must stay exclusive portrait: with landscape still allowed at rest UIKit saw no
    /// reason to rotate and browse stayed stuck sideways. No-op on iPad (never managed).
    func endPlayerPresentation() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        apply(browseDefault)
    }

    /// Force the player to a specific orientation (iPhone only) — the rotate button's
    /// action, only meaningful while the player's wide mask is active. The mask stays WIDE
    /// (portrait+landscape); this one-shot geometry request OVERRIDES the system rotation
    /// lock, which is the whole point of the button. `target` is `.landscapeLeft` (a single
    /// side — Dynamic Island on the right, the user's grip; with the lock on UIKit has no
    /// physical side to prefer from a pair) or `.portrait`. Invalidate-then-request is
    /// harmless here (the wide mask already contains `target`) but keeps one rotation code
    /// path.
    func rotatePlayer(to target: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        forceRotation(to: target)
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

    /// Invalidate the delegate-vended mask so UIKit re-queries
    /// `application(_:supportedInterfaceOrientationsFor:)`. The present path uses this
    /// ALONE (no geometry request — the device drives); `forceRotation` chains it before
    /// the request.
    private func invalidateSupportedOrientations() {
        activeWindowScene?.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// The two UIKit calls that turn the vended mask into an actual rotation.
    /// Invalidate BEFORE requesting: the geometry request is validated against the
    /// scene's CACHED resolved orientations, and with exclusive masks the stale cache
    /// never contains the requested orientation — requested-after-invalidated is the
    /// difference between rotating and a silent UISceneErrorDomain 101 rejection
    /// (sim-reproduced; the player mounted in portrait).
    private func forceRotation(to newMask: UIInterfaceOrientationMask) {
        invalidateSupportedOrientations()
        activeWindowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: newMask))
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

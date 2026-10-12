import Observation

/// What the app root's scene is doing, forwarded from SwiftUI's `ScenePhase` so the package never
/// imports SwiftUI.
public enum SceneActivity: Sendable {
    case active
    case inactive
    case background
}

/// Turns the scene's activity into the one edge the flows care about: a genuine return from the
/// background.
///
/// Cold launch settles through the same inactive-to-active transition as a foreground return, and a
/// Control Center pull or a tvOS screensaver dismiss is an inactive-to-active blip too, so the
/// previous activity alone can't tell them apart. Only an `.active` that follows a `.background`
/// counts. Every `.active` consumes that history, whether or not anyone acted on it.
@Observable
@MainActor
public final class AppLifecycle {
    /// Moves once per return from the background.
    public private(set) var foregroundReturns = 0
    private var hasBeenBackgrounded = false

    public init() {}

    public func update(_ activity: SceneActivity) {
        switch activity {
        case .background:
            hasBeenBackgrounded = true
        case .inactive:
            break
        case .active:
            if hasBeenBackgrounded { foregroundReturns += 1 }
            hasBeenBackgrounded = false
        }
    }
}

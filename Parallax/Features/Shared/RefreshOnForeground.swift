import SwiftUI

extension View {
    /// Silently revalidate on a genuine background→foreground return, and ONLY that.
    ///
    /// Contract, in the order the checks apply:
    ///  - the scene must have actually reached `.background` since the last `.active` edge. An
    ///    `.inactive → .active` blip (a Control Center pull, a tvOS screensaver dismiss) never
    ///    fires, and neither does launch's first activation — nothing is stale yet.
    ///  - EVERY `.active` edge consumes that history, whether or not it fired. A covered or
    ///    disabled instance that skipped its turn is not owed one later: keeping the flag set
    ///    would arm the next blip, which is exactly the edge the previous rule excludes.
    ///  - the view must be visible. A `NavigationStack`-covered level gets `onDisappear` and must
    ///    not refresh under the top of the stack.
    ///  - `isEnabled` must be true. For a level whose content is still mounted but must not be
    ///    disturbed — the iOS player is an overlay, so the browse wall under it never disappears.
    ///  - only ONE action runs at a time. The action is async (a pool flush, then a re-list), and
    ///    a second edge arriving mid-flight would start a duplicate over the first; same latch
    ///    idea as `RecoversFromOffline.isRecovering`.
    ///
    /// Attach on a stable container alongside `.task`, not inside a loading/error branch, so the
    /// observers stay mounted across state flips.
    func refreshesOnForeground(
        isEnabled: Bool = true,
        action: @escaping () async -> Void
    ) -> some View {
        modifier(RefreshOnForeground(isEnabled: isEnabled, action: action))
    }
}

private struct RefreshOnForeground: ViewModifier {
    let isEnabled: Bool
    let action: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    /// Set when the scene is observed as `.background`, and cleared on EVERY `.active` edge — not
    /// only the ones that fire. A covered / disabled instance that skips its turn must not keep a
    /// stale `true` around, or a later Control Center `.inactive → .active` blip would fire on it.
    @State private var hasBeenBackgrounded = false
    /// Tracks whether the modified view is on screen. A pushed-over level receives `onDisappear`
    /// while covered; only the currently visible top of the stack should react to foregrounding.
    @State private var isVisible = false
    /// True while the action Task runs. Further edges are ignored until it returns, so two
    /// foreground events in quick succession can't stack two refreshes over each other.
    @State private var isRefreshing = false

    func body(content: Content) -> some View {
        content
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    hasBeenBackgrounded = true
                    return
                }
                guard phase == .active else { return }
                let shouldFire = hasBeenBackgrounded && isVisible && isEnabled && !isRefreshing
                hasBeenBackgrounded = false
                guard shouldFire else { return }
                isRefreshing = true
                Task {
                    await action()
                    isRefreshing = false
                }
            }
    }
}

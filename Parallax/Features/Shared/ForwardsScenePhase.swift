import SwiftUI
import ParallaxFeatures

extension View {
    /// Hands the scene's phase to the package, which owns what a foreground return means.
    func forwardsScenePhase(to lifecycle: AppLifecycle) -> some View {
        modifier(ScenePhaseForwarder(lifecycle: lifecycle))
    }
}

private struct ScenePhaseForwarder: ViewModifier {
    let lifecycle: AppLifecycle
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase, initial: true) { _, phase in
            lifecycle.update(SceneActivity(phase))
        }
    }
}

private extension SceneActivity {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        case .inactive: self = .inactive
        @unknown default: self = .inactive
        }
    }
}

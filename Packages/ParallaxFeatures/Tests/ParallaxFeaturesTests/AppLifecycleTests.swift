import ParallaxFeatures
import Testing
import ParallaxTestScaling

@MainActor
@Suite("AppLifecycle", .scaledTimeLimit())
struct AppLifecycleTests {
    @Test(
        "only an activation that follows the background counts as a return, and every activation counts as one",
        arguments: [
            (activities: [.active], returns: 0, activations: 1),
            (activities: [.inactive, .active], returns: 0, activations: 1),
            (activities: [.background, .active], returns: 1, activations: 1),
            (activities: [.background, .inactive, .active], returns: 1, activations: 1),
            (activities: [.background, .active, .inactive, .active], returns: 1, activations: 2),
            (activities: [.background, .active, .background, .active], returns: 2, activations: 2),
        ] as [(activities: [SceneActivity], returns: Int, activations: Int)]
    )
    func countsReturnsFromTheBackground(activities: [SceneActivity], returns: Int, activations: Int) {
        let lifecycle = AppLifecycle()

        activities.forEach(lifecycle.update)

        #expect(lifecycle.foregroundReturns == returns)
        #expect(lifecycle.activations == activations)
    }
}

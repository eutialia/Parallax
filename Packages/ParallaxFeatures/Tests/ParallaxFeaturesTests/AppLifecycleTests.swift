import ParallaxFeatures
import Testing

@MainActor
@Suite("AppLifecycle")
struct AppLifecycleTests {
    @Test(
        "only an activation that follows the background counts as a return",
        arguments: [
            (activities: [.active], returns: 0),
            (activities: [.inactive, .active], returns: 0),
            (activities: [.background, .active], returns: 1),
            (activities: [.background, .inactive, .active], returns: 1),
            (activities: [.background, .active, .inactive, .active], returns: 1),
            (activities: [.background, .active, .background, .active], returns: 2),
        ] as [(activities: [SceneActivity], returns: Int)]
    )
    func countsReturnsFromTheBackground(activities: [SceneActivity], returns: Int) {
        let lifecycle = AppLifecycle()

        activities.forEach(lifecycle.update)

        #expect(lifecycle.foregroundReturns == returns)
    }
}

import ParallaxFeatures
import ParallaxPlayback
import Testing
import ParallaxTestScaling

@MainActor
@Suite("Subtitle preferences", .scaledTimeLimit())
struct SubtitlePreferenceScenarios {
    @Test("a subtitle style change survives a relaunch")
    func styleSurvivesRelaunch() async throws {
        let world = try await AppWorld.launch()
        let style = SubtitleStyle.standard.with {
            $0.fontScale = 1.5
            $0.fontDesign = .serif
        }
        #expect(world.app.subtitlePreferences.style == .standard)

        world.app.subtitlePreferences.update(style)
        try await world.until { () async in world.persistedSubtitleStyle == style }
        await world.relaunch()

        try await world.until { world.app.subtitlePreferences.style == style }
    }
}

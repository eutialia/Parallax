import Foundation
import ParallaxFeatures
import ParallaxPlayback
import Testing

@MainActor
@Suite("Subtitle styles older builds saved", .timeLimit(.minutes(1)))
struct SubtitleStyleLegacyScenarios {

    /// A style as builds before the boxless look saved it: with the ring and shadow geometry this
    /// build no longer stores, and with a font design and background spelled as they wrote them.
    private static func savedBlob(fontDesign: String, background: String) -> Data {
        Data(#"{"foreground":{"red":0.1,"green":0.2,"blue":0.3,"alpha":0.9},"outline":{"red":0,"green":0,"blue":0,"alpha":1},"outlineWidthRatio":0.06,"shadowOpacity":0.55,"shadowYOffsetRatio":0.04,"fontScale":1.5,"fontDesign":"\#(fontDesign)","background":"\#(background)","verticalOffsetRatio":0.12}"#.utf8)
    }

    @Test("a subtitle style an older build saved loads with its colour, size and position, and a font this build no longer has reads as sans",
          arguments: [
              ("sansSerif", "outlineShadow", SubtitleFontDesign.sansSerif, SubtitleBackground.outline),
              ("serif", "opaqueBox", .serif, .opaqueBox),
              ("monospaced", "outlineShadow", .sansSerif, .outline),
              ("someFutureDesign", "opaqueBox", .sansSerif, .opaqueBox),
          ])
    func olderStyleLoads(
        fontDesign: String, background: String, design: SubtitleFontDesign, backing: SubtitleBackground
    ) async throws {
        let expected = SubtitleStyle(
            foreground: SubtitleStyle.RGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9),
            fontScale: 1.5, fontDesign: design, background: backing, verticalOffsetRatio: 0.12)

        let world = try await AppWorld.launch(savedSettings: [
            SubtitlePreferences.key.name: Self.savedBlob(fontDesign: fontDesign, background: background),
        ])

        try await world.until { world.app.subtitlePreferences.style == expected }
    }
}

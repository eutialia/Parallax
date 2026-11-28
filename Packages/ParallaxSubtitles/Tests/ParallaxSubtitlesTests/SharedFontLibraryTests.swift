import Foundation
import ParallaxSubtitles
import Testing

/// Every renderer in the process draws from one font library: the player's subtitle and
/// the Settings preview at once, and each subtitle picked after the last.
@Suite("Shared font library")
struct SharedFontLibraryTests {
    /// `zh-arial.ass` and `zh-mincho.ass` draw the same Chinese line, one from the sans face
    /// and one from the serif.
    @Test("two subtitles drawing at once, the player's and the Settings preview's, each draw their own text")
    func twoSubtitlesDrawAtOnce() async throws {
        let sansAlone = try await drawing(of: "zh-arial.ass", at: 1.5)
        let serifAlone = try await drawing(of: "zh-mincho.ass", at: 1.5)
        let sans = try await loaded("zh-arial.ass")
        let serif = try await loaded("zh-mincho.ass")

        let drawn = try await withThrowingTaskGroup(of: (Bool, Drawing).self) { group in
            for _ in 0..<20 {
                group.addTask { (true, try await sans.drawing(at: 1.5)) }
                group.addTask { (false, try await serif.drawing(at: 1.5)) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(sansAlone != serifAlone)
        #expect(drawn.count == 40)
        for (isSans, drawing) in drawn {
            #expect(drawing == (isSans ? sansAlone : serifAlone))
        }
    }

    /// `embedded-font.ass` attaches a font whose only glyph, A, is a solid square, and names
    /// it as its style font. `letter-a.srt` is a line of As.
    @Test("a subtitle's embedded font is never drawn, by that subtitle or a later one")
    func embeddedFontIsNeverDrawn() async throws {
        let carrier = try await drawing(of: "embedded-font.ass", at: 1.5)
        let noto = SubtitleStyleOverride(fontFamily: SubtitleFontBundle.sansFamily)
        #expect(carrier == (try await drawing(of: "embedded-font.ass", at: 1.5, style: noto)))

        let named = SubtitleStyleOverride(fontFamily: "ParallaxEmbeddedProbe")
        #expect(try await drawing(of: "letter-a.srt", at: 1.5, style: named) == (try await drawing(of: "letter-a.srt", at: 1.5)))
    }

    /// The Chinese faces join the library the first time a track needs them, after the
    /// renderer that later needs them was made.
    @Test("a second Chinese subtitle in the same session draws its Chinese")
    func laterChineseSubtitleDrawsItsChinese() async throws {
        let subtitle = try await loaded("sidecar.srt")
        _ = try await subtitle.drawing(at: 1.5)

        try await subtitle.renderer.load(try fixture("zh-simple.srt"), format: .srt)

        #expect(try await subtitle.drawing(at: 1.5) == (try await drawing(of: "zh-simple.srt", at: 1.5)))
    }
}

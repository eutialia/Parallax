import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxPlayback
import Testing

/// How the subtitle menu names the subtitle files beside an SMB film, from the tags in their names.
@MainActor
@Suite("Subtitle file names on an SMB film", .timeLimit(.minutes(1)))
struct SubtitleSMBLabelScenarios {
    private static let line = Data("1\n00:00:01,000 --> 00:00:04,000\nThe heat is on.\n".utf8)

    struct Row: Hashable, CustomStringConvertible {
        let name: String
        let language: String?
        let sdh: Bool
        let forced: Bool
        let detail: String?

        var description: String { "\(name) [\(language ?? "-")\(sdh ? " SDH" : "")\(forced ? " forced" : "")] \(detail ?? "")" }
    }

    private static func language(_ tag: String) throws -> String {
        try #require(TrackDisplay.languageName(tag))
    }

    @Test("the subtitle menu of an SMB film names each subtitle file by the languages its name tags, with SDH and forced read from the name, and shows a name with no language tag as written")
    func subtitleFilesAreNamedByTheirTags() async throws {
        let files = [
            "Heat.zh.hi.srt", "Heat.en.forced.ass", "Heat.jptc.ass", "Heat.chs.ass", "Heat.big5gb.ass",
            "Heat.en.signs songs.ass", "Heat.commentary.srt", "Heat.en-GB.srt", "Heat.zh_Hans.srt", "Heat.swe.srt",
            "Heat.sc-team.srt", "Heat.sv-SE.vtt", "Heat.por-BR.srt", "Heat.zh-TW.vtt", "Heat.cze.srt",
        ]
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        try await world.playSMBFilm(beside: Dictionary(uniqueKeysWithValues: files.map { ($0, Self.line) }))
        let player = try await world.openPlayer()

        let english = try Self.language("en"), japanese = try Self.language("ja")
        let simplified = try Self.language("zh-Hans"), traditional = try Self.language("zh-Hant")
        let swedish = try Self.language("sv")
        let expected: Set<Row> = [
            Row(name: try Self.language("zh"), language: "zh", sdh: true, forced: false, detail: "SRT · External"),
            Row(name: english, language: "en", sdh: false, forced: true, detail: "ASS · External"),
            Row(name: "\(japanese) + \(traditional)", language: "ja", sdh: false, forced: false, detail: "ASS · External"),
            Row(name: simplified, language: "zh-Hans", sdh: false, forced: false, detail: "ASS · External"),
            Row(name: "\(traditional) + \(simplified)", language: "zh-Hant", sdh: false, forced: false, detail: "ASS · External"),
            Row(name: "\(english) (Signs & Songs)", language: "en", sdh: false, forced: false, detail: "ASS · External"),
            Row(name: "Commentary", language: nil, sdh: false, forced: false, detail: "SRT · External"),
            Row(name: english, language: "en", sdh: false, forced: false, detail: "SRT · External"),
            Row(name: simplified, language: "zh-Hans", sdh: false, forced: false, detail: "SRT · External"),
            Row(name: swedish, language: "sv", sdh: false, forced: false, detail: "SRT · External"),
            Row(name: "sc-team", language: nil, sdh: false, forced: false, detail: "SRT · External"),
            Row(name: swedish, language: "sv", sdh: false, forced: false, detail: "VTT · External"),
            Row(name: try Self.language("pt"), language: "pt", sdh: false, forced: false, detail: "SRT · External"),
            Row(name: traditional, language: "zh-Hant", sdh: false, forced: false, detail: "VTT · External"),
            Row(name: try Self.language("cs"), language: "cs", sdh: false, forced: false, detail: "SRT · External"),
        ]

        let rows = player.availableSubtitleTracks.map {
            Row(name: $0.displayName, language: $0.languageCode, sdh: $0.isSDH, forced: $0.isForced, detail: $0.detailLabel)
        }
        #expect(rows.count == files.count)
        #expect(Set(rows) == expected, "\(Set(rows).symmetricDifference(expected))")
    }
}

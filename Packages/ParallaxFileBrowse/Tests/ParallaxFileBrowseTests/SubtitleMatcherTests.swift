import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Drives the synthesized matcher matrix directly (no lister/I-O), one assertion per filename pair.
/// `expected == nil` means "must not match"; otherwise it is the exact label.
@Suite("SubtitleMatcher")
struct SubtitleMatcherTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let video: String
        let sub: String
        let lonely: Bool
        let expected: String?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // ---- Regression: the existing exact/suffix behavior must be byte-preserved ----
        .init(name: "exact stem → Default", video: "Movie.mkv", sub: "Movie.srt", lonely: false, expected: "Default"),
        .init(name: "dot-suffix → en", video: "Movie.mkv", sub: "Movie.en.srt", lonely: false, expected: "en"),
        .init(name: "exact stem other ext → Default", video: "Movie.mkv", sub: "Movie.ass", lonely: false, expected: "Default"),
        .init(name: "multi-token suffix verbatim", video: "Movie.mkv", sub: "Movie.en.forced.srt", lonely: false, expected: "en.forced"),
        .init(name: "case-insensitive, lowercased label", video: "Movie.mkv", sub: "movie.EN.srt", lonely: false, expected: "en"),
        .init(name: "prefix sequel Movie2 rejected", video: "Movie.mkv", sub: "Movie2.srt", lonely: false, expected: nil),
        .init(name: "prefix-no-boundary rejected", video: "Movie.mkv", sub: "MovieExtra.en.srt", lonely: false, expected: nil),
        .init(name: "unrelated title rejected", video: "Movie.mkv", sub: "OtherMovie.srt", lonely: false, expected: nil),
        .init(name: "empty dot-suffix rejected", video: "Movie.mkv", sub: "Movie..srt", lonely: false, expected: nil),
        .init(name: "no-ext video exact", video: "Movie", sub: "Movie.srt", lonely: false, expected: "Default"),
        .init(name: "no-ext video suffix", video: "Movie", sub: "Movie.en.srt", lonely: false, expected: "en"),

        // ---- The user's report + the loosening it asks for ----
        .init(name: "user example (clean suffix)",
              video: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              sub: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].JPTC.ass",
              lonely: false, expected: "jptc"),
        .init(name: "drifted tags, same episode",
              video: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              sub: "[Nekomoe kissaten] Soredemo Ayumu wa Yosetekuru [01].JPTC.ass",
              lonely: false, expected: "jptc"),
        .init(name: "adjacent episode hard-reject",
              video: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              sub: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [02][Ma10p_1080p][x265_flac].JPTC.ass",
              lonely: false, expected: nil),

        // ---- Anime season folder (many videos + many subs) ----
        .init(name: "CRC differs, same episode",
              video: "[Group] Bocchi the Rock! [01][Ma10p_1080p][abcd1234].mkv",
              sub: "[Group] Bocchi the Rock! [01][Ma10p_1080p][ef567890].CHT.ass",
              lonely: false, expected: "cht"),
        .init(name: "different group → group label",
              video: "[SubsPlease] Kanojo - 01 (1080p) [9A2B3C4D].mkv",
              sub: "[Erai-raws] Kanojo - 01 [Multiple Subtitle][1080p][AABBCCDD].ass",
              lonely: false, expected: "erai-raws"),
        .init(name: "extra [CHS&CHT] bracket → chs.cht",
              video: "[Erai-raws] Spy x Family - 12 [1080p][ABCD1234].mkv",
              sub: "[Erai-raws] Spy x Family - 12 [1080p][ABCD1234][CHS&CHT].ass",
              lonely: false, expected: "chs.cht"),
        .init(name: "extra [sc_jp] bracket → sc.jp",
              video: "[VCB-Studio] Violet Evergarden [01][Hi10p_1080p][x264_flac].mkv",
              sub: "[VCB-Studio] Violet Evergarden [01][Hi10p_1080p][x264_flac][sc_jp].ass",
              lonely: false, expected: "sc.jp"),
        .init(name: "01v2 == 01",
              video: "[Nekomoe] Lycoris Recoil [01v2][1080p].mkv",
              sub: "[Nekomoe] Lycoris Recoil [01][1080p].JPTC.ass",
              lonely: false, expected: "jptc"),
        .init(name: "episode-only sub matches",
              video: "[Group] Show [05][1080p].mkv", sub: "05.JPSC.ass", lonely: false, expected: "jpsc"),
        .init(name: "episode-only sub wrong number",
              video: "[Group] Show [05][1080p].mkv", sub: "06.JPSC.ass", lonely: false, expected: nil),
        .init(name: "different show same episode rejected",
              video: "[Group] Show A [01][1080p].mkv", sub: "[Group] Show B [01][1080p].chs.ass",
              lonely: false, expected: nil),
        .init(name: "season folder adjacent dash-episode",
              video: "[SubsPlease] Frieren - 01 (1080p) [11223344].mkv",
              sub: "[SubsPlease] Frieren - 02 (1080p) [55667788].srt",
              lonely: false, expected: nil),

        // ---- Western TV ----
        .init(name: "S01E02 drifted-tag sub",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", sub: "Show.Name.S01E02.en.srt",
              lonely: false, expected: "en"),
        .init(name: "S01E02 different release",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", sub: "Show.Name.S01E02.720p.HDTV.x264-OTHER.en.srt",
              lonely: false, expected: "en"),
        .init(name: "S01E02 vs S01E03 rejected",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", sub: "Show.Name.S01E03.en.srt",
              lonely: false, expected: nil),
        .init(name: "S01E02 vs S02E02 rejected",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", sub: "Show.Name.S02E02.en.srt",
              lonely: false, expected: nil),
        .init(name: "1x05 Kodi style",
              video: "Breaking.Bad.1x05.HDTV.mkv", sub: "Breaking.Bad.1x05.eng.srt",
              lonely: false, expected: "eng"),

        // ---- Movies ----
        .init(name: "movie title+year, no lang → Default",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2021.srt",
              lonely: false, expected: "Default"),
        .init(name: "year conflict rejected",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2019.eng.srt",
              lonely: false, expected: nil),
        .init(name: "sequel differentiator rejected",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2.2021.srt",
              lonely: false, expected: nil),

        // ---- Special-content + multi-part guards ----
        .init(name: "NCED vs episode rejected",
              video: "[Group] Anime [05][1080p].mkv", sub: "[Group] Anime NCED [1080p].ass",
              lonely: false, expected: nil),
        .init(name: "OP vs episode rejected",
              video: "[Group] Anime [05][1080p].mkv", sub: "[Group] Anime OP [1080p].srt",
              lonely: false, expected: nil),
        // DEVIATION from spec matrix: a `.sample.srt` with a BYTE-IDENTICAL base is the same
        // content's sample, not a cross-attach — T1/T2 stay guard-free, so it attaches as "sample".
        .init(name: "sample suffix on identical base attaches",
              video: "[Group] Show [01][1080p].mkv", sub: "[Group] Show [01][1080p].sample.srt",
              lonely: false, expected: "sample"),
        .init(name: "CD1 vs CD2 rejected", video: "TheMovie.CD1.avi", sub: "TheMovie.CD2.srt", lonely: false, expected: nil),
        .init(name: "CD1 matched suffix", video: "TheMovie.CD1.avi", sub: "TheMovie.CD1.eng.srt", lonely: false, expected: "eng"),

        // ---- Lonely-video fallback ----
        .init(name: "lonely: arbitrary sub → Default",
              video: "[OnlyVid] Standalone Film [BD_1080p].mkv", sub: "random_subtitle_dump.ass",
              lonely: true, expected: "Default"),
        .init(name: "lonely: recovered language",
              video: "TheOnlyMovieHere.1080p.x265.mkv", sub: "english_subs_final.srt",
              lonely: true, expected: "english"),
        .init(name: "lonely: translator dump → Default",
              video: "Random.Fansub.Episode.Name.mkv", sub: "different-translator-release.srt",
              lonely: true, expected: "Default"),
        .init(name: "multi-video anchorless sub rejected",
              video: "Show.Name.S01E01.1080p.mkv", sub: "english.srt", lonely: false, expected: nil),
        // DEVIATION: T2 returns the suffix verbatim (zero-regression), so "zh-Hans" stays "zh-hans".
        .init(name: "OVA special suffix verbatim",
              video: "[Group] Some OVA Special.mkv", sub: "[Group] Some OVA Special.zh-Hans.ass",
              lonely: false, expected: "zh-hans"),

        // ---- Review regressions ----
        // #1: a title digit-run ("13") must survive when the episode marker ("3") is a substring of it.
        // The old global replacingOccurrences mangled "13"→"1" asymmetrically and dropped this match.
        .init(name: "title digit-run survives episode-marker strip",
              video: "Apollo 13 - 3 [1080p].mkv", sub: "Apollo 13 - 03.JPTC.ass",
              lonely: false, expected: "jptc"),
        // #2: sequel numbers beyond the old hardcoded set (2,3,4) must still reject.
        .init(name: "high arabic sequel rejected", video: "Movie 7.mkv", sub: "Movie.eng.srt", lonely: false, expected: nil),
        .init(name: "roman sequel rejected", video: "Movie VII.mkv", sub: "Movie.eng.srt", lonely: false, expected: nil),
        // #4: a multi-episode batch range " - 12-13 " extracts the span and matches its own sub.
        .init(name: "batch episode span matches",
              video: "[Grp] Show - 12-13 [1080p].mkv", sub: "[Grp] Show - 12-13.JPTC.ass",
              lonely: false, expected: "jptc"),
        .init(name: "batch span conflict rejected",
              video: "[Grp] Show - 12-13 [1080p].mkv", sub: "[Grp] Show - 14-15.JPTC.ass",
              lonely: false, expected: nil),
    ]

    @Test("matrix", arguments: cases)
    func matrix(_ c: Case) {
        let video = SubtitleMatcher.NameModel(filename: c.video)
        let sub = SubtitleMatcher.NameModel(filename: c.sub)
        let label = SubtitleMatcher.label(forSub: sub, video: video, lonelyVideo: c.lonely)
        #expect(label == c.expected, "\(c.name): got \(label.map { "\"\($0)\"" } ?? "nil"), expected \(c.expected.map { "\"\($0)\"" } ?? "nil")")
    }
}

import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Drives the matcher directly (no lister/I-O), one assertion per filename pair.
/// `expected == nil` means "must not match"; otherwise it is the exact label.
///
/// The cases are grouped by the rule they exercise rather than pooled into one giant matrix, so a
/// failure names the tier that broke instead of just "matrix".
@Suite("SubtitleMatcher")
struct SubtitleMatcherTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let video: String
        let sub: String
        let lonely: Bool
        let expected: String?

        init(_ name: String, video: String, sub: String, lonely: Bool = false, expected: String?) {
            self.name = name
            self.video = video
            self.sub = sub
            self.lonely = lonely
            self.expected = expected
        }

        var testDescription: String { name }
    }

    private func verify(_ testCase: Case, sourceLocation: SourceLocation = #_sourceLocation) {
        let video = SubtitleMatcher.NameModel(filename: testCase.video)
        let sub = SubtitleMatcher.NameModel(filename: testCase.sub)
        let label = SubtitleMatcher.label(forSub: sub, video: video, lonelyVideo: testCase.lonely)
        #expect(label == testCase.expected,
                "\(testCase.name): got \(label.map { "\"\($0)\"" } ?? "nil"), expected \(testCase.expected.map { "\"\($0)\"" } ?? "nil")",
                sourceLocation: sourceLocation)
    }

    // MARK: - T1/T2 — exact stem and dot-suffix

    static let exactAndSuffix: [Case] = [
        .init("exact stem → Default", video: "Movie.mkv", sub: "Movie.srt", expected: "Default"),
        .init("exact stem other ext → Default", video: "Movie.mkv", sub: "Movie.ass", expected: "Default"),
        .init("dot-suffix → en", video: "Movie.mkv", sub: "Movie.en.srt", expected: "en"),
        .init("multi-token suffix verbatim", video: "Movie.mkv", sub: "Movie.en.forced.srt", expected: "en.forced"),
        .init("case-insensitive, lowercased label", video: "Movie.mkv", sub: "movie.EN.srt", expected: "en"),
        .init("empty dot-suffix rejected", video: "Movie.mkv", sub: "Movie..srt", expected: nil),
        .init("no-ext video exact", video: "Movie", sub: "Movie.srt", expected: "Default"),
        .init("no-ext video suffix", video: "Movie", sub: "Movie.en.srt", expected: "en"),
        // DEVIATION from the spec matrix: a `.sample.srt` with a BYTE-IDENTICAL base is the same
        // content's sample, not a cross-attach — T1/T2 stay guard-free, so it attaches as "sample".
        .init("sample suffix on identical base attaches",
              video: "[Group] Show [01][1080p].mkv", sub: "[Group] Show [01][1080p].sample.srt", expected: "sample"),
        // DEVIATION: T2 returns the suffix verbatim (zero-regression), so "zh-Hans" stays "zh-hans".
        .init("OVA special suffix verbatim",
              video: "[Group] Some OVA Special.mkv", sub: "[Group] Some OVA Special.zh-Hans.ass", expected: "zh-hans"),
    ]

    @Test("T1/T2 — exact stem and dot-suffix", arguments: exactAndSuffix)
    func exactAndSuffixTier(_ testCase: Case) { verify(testCase) }

    // MARK: - T3 — same episode, drifted release tags

    static let driftedEpisode: [Case] = [
        .init("clean suffix on a long release name",
              video: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              sub: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].JPTC.ass",
              expected: "jptc"),
        .init("drifted tags, same episode",
              video: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              sub: "[Nekomoe kissaten] Soredemo Ayumu wa Yosetekuru [01].JPTC.ass",
              expected: "jptc"),
        .init("CRC differs, same episode",
              video: "[Group] Bocchi the Rock! [01][Ma10p_1080p][abcd1234].mkv",
              sub: "[Group] Bocchi the Rock! [01][Ma10p_1080p][ef567890].CHT.ass",
              expected: "cht"),
        .init("different group with no language → group label",
              video: "[SubsPlease] Kanojo - 01 (1080p) [9A2B3C4D].mkv",
              sub: "[Erai-raws] Kanojo - 01 [Multiple Subtitle][1080p][AABBCCDD].ass",
              expected: "erai-raws"),
        // Nothing distinguishes the sub — same group, no language — so the episode itself is the label.
        .init("same group, no language → episode anchor",
              video: "[Group] Show [05][1080p][abcd1234].mkv",
              sub: "[Group] Show [05][720p].ass",
              expected: "ep5"),
        .init("extra [CHS&CHT] bracket → chs.cht",
              video: "[Erai-raws] Spy x Family - 12 [1080p][ABCD1234].mkv",
              sub: "[Erai-raws] Spy x Family - 12 [1080p][ABCD1234][CHS&CHT].ass",
              expected: "chs.cht"),
        .init("extra [sc_jp] bracket → sc.jp",
              video: "[VCB-Studio] Violet Evergarden [01][Hi10p_1080p][x264_flac].mkv",
              sub: "[VCB-Studio] Violet Evergarden [01][Hi10p_1080p][x264_flac][sc_jp].ass",
              expected: "sc.jp"),
        .init("01v2 == 01", video: "[Nekomoe] Lycoris Recoil [01v2][1080p].mkv",
              sub: "[Nekomoe] Lycoris Recoil [01][1080p].JPTC.ass", expected: "jptc"),
        .init("episode-only sub matches", video: "[Group] Show [05][1080p].mkv", sub: "05.JPSC.ass", expected: "jpsc"),
        .init("S01E02 drifted-tag sub",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", sub: "Show.Name.S01E02.en.srt", expected: "en"),
        .init("S01E02 different release",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv",
              sub: "Show.Name.S01E02.720p.HDTV.x264-OTHER.en.srt", expected: "en"),
        .init("1x05 Kodi style", video: "Breaking.Bad.1x05.HDTV.mkv", sub: "Breaking.Bad.1x05.eng.srt", expected: "eng"),
        // Episode read from the "EP05" keyword form rather than a bracket, dash or SxxExx marker.
        .init("explicit EP keyword, drifted quality tag",
              video: "Show EP05 1080p.mkv", sub: "Show EP05 720p.en.srt", expected: "en"),
        // Review regression #1: a title digit-run ("13") must survive when the episode marker ("3")
        // is a substring of it — a global replace mangled "13"→"1" and dropped this match.
        .init("title digit-run survives episode-marker strip",
              video: "Apollo 13 - 3 [1080p].mkv", sub: "Apollo 13 - 03.JPTC.ass", expected: "jptc"),
        // Review regression #4: a multi-episode batch range " - 12-13 " extracts the span.
        .init("batch episode span matches",
              video: "[Grp] Show - 12-13 [1080p].mkv", sub: "[Grp] Show - 12-13.JPTC.ass", expected: "jptc"),
    ]

    @Test("T3 — same episode across drifted release tags", arguments: driftedEpisode)
    func driftedEpisodeTier(_ testCase: Case) { verify(testCase) }

    // MARK: - T4 — no episode either side

    static let noEpisode: [Case] = [
        .init("movie title+year, no lang → Default",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2021.srt", expected: "Default"),
        .init("CD1 matched suffix", video: "TheMovie.CD1.avi", sub: "TheMovie.CD1.eng.srt", expected: "eng"),
    ]

    @Test("T4 — no episode on either side", arguments: noEpisode)
    func noEpisodeTier(_ testCase: Case) { verify(testCase) }

    // MARK: - Hyphenated BCP-47 language components (review fix)
    //
    // A hyphenated filename component ("en-GB", "zh-Hant", "pt-BR") is a single BCP-47 unit and
    // must resolve WHOLE (via `SubtitleLabelInfo.bcp47Tag`) before any hyphen-splitting — splitting
    // first previously misread "en-GB" as language "en" + fansub token "gb" (zh-Hans), producing
    // "English + Chinese, Simplified" for a plain British-English track.

    static let hyphenatedLanguage: [Case] = [
        .init("T4 region tag resolves whole → en-gb (not en + fansub gb)",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2021.en-GB.srt",
              expected: "en-gb"),
        .init("T4 script tag resolves whole → zh-hant",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2021.zh-Hant.srt",
              expected: "zh-hant"),
        .init("T4 region tag resolves whole → pt-br",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2021.pt-BR.srt",
              expected: "pt-br"),
        .init("T5 lonely-video whole-unit region tag",
              video: "TheOnlyMovieHere.1080p.x265.mkv", sub: "subtitle.en-GB.srt",
              lonely: true, expected: "en-gb"),
        // A hyphen that is NOT a whole BCP-47 unit still falls through to the split scan — the fix
        // must not regress a trailing language token onto a non-language hyphen prefix.
        .init("non-BCP-47 hyphen still splits to recover a trailing language token",
              video: "Movie.mkv", sub: "Movie-EN.srt", expected: "en"),
        // Control: a bare fansub token with no hyphen is untouched by the whole-unit check.
        .init("bare fansub token unaffected by hyphen handling",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2021.gb.srt",
              expected: "gb"),
    ]

    @Test("Hyphenated BCP-47 components resolve whole before splitting", arguments: hyphenatedLanguage)
    func hyphenatedLanguageTier(_ testCase: Case) { verify(testCase) }

    // MARK: - Hard rejects

    static let hardRejects: [Case] = [
        .init("prefix sequel Movie2 rejected", video: "Movie.mkv", sub: "Movie2.srt", expected: nil),
        .init("prefix-no-boundary rejected", video: "Movie.mkv", sub: "MovieExtra.en.srt", expected: nil),
        .init("unrelated title rejected", video: "Movie.mkv", sub: "OtherMovie.srt", expected: nil),
        .init("adjacent episode hard-reject",
              video: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              sub: "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [02][Ma10p_1080p][x265_flac].JPTC.ass",
              expected: nil),
        .init("episode-only sub wrong number", video: "[Group] Show [05][1080p].mkv", sub: "06.JPSC.ass", expected: nil),
        .init("different show same episode rejected",
              video: "[Group] Show A [01][1080p].mkv", sub: "[Group] Show B [01][1080p].chs.ass", expected: nil),
        .init("season folder adjacent dash-episode",
              video: "[SubsPlease] Frieren - 01 (1080p) [11223344].mkv",
              sub: "[SubsPlease] Frieren - 02 (1080p) [55667788].srt", expected: nil),
        .init("S01E02 vs S01E03 rejected",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", sub: "Show.Name.S01E03.en.srt", expected: nil),
        .init("S01E02 vs S02E02 rejected",
              video: "Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", sub: "Show.Name.S02E02.en.srt", expected: nil),
        .init("year conflict rejected",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2019.eng.srt", expected: nil),
        .init("sequel differentiator rejected",
              video: "Movie.Title.2021.1080p.BluRay.x264.mkv", sub: "Movie.Title.2.2021.srt", expected: nil),
        // Review regression #2: sequel numbers beyond the old hardcoded set (2,3,4) must still reject.
        .init("high arabic sequel rejected", video: "Movie 7.mkv", sub: "Movie.eng.srt", expected: nil),
        .init("roman sequel rejected", video: "Movie VII.mkv", sub: "Movie.eng.srt", expected: nil),
        .init("NCED vs episode rejected",
              video: "[Group] Anime [05][1080p].mkv", sub: "[Group] Anime NCED [1080p].ass", expected: nil),
        .init("OP vs episode rejected",
              video: "[Group] Anime [05][1080p].mkv", sub: "[Group] Anime OP [1080p].srt", expected: nil),
        .init("CD1 vs CD2 rejected", video: "TheMovie.CD1.avi", sub: "TheMovie.CD2.srt", expected: nil),
        .init("batch span conflict rejected",
              video: "[Grp] Show - 12-13 [1080p].mkv", sub: "[Grp] Show - 14-15.JPTC.ass", expected: nil),
        .init("multi-video anchorless sub rejected",
              video: "Show.Name.S01E01.1080p.mkv", sub: "english.srt", expected: nil),
    ]

    @Test("Hard rejects — episode/season/year/part/special/sequel conflicts", arguments: hardRejects)
    func hardRejectGuards(_ testCase: Case) { verify(testCase) }

    // MARK: - T5 — lonely-video fallback

    static let lonelyVideo: [Case] = [
        .init("arbitrary sub → Default", video: "[OnlyVid] Standalone Film [BD_1080p].mkv",
              sub: "random_subtitle_dump.ass", lonely: true, expected: "Default"),
        .init("recovered language", video: "TheOnlyMovieHere.1080p.x265.mkv",
              sub: "english_subs_final.srt", lonely: true, expected: "english"),
        .init("translator dump → Default", video: "Random.Fansub.Episode.Name.mkv",
              sub: "different-translator-release.srt", lonely: true, expected: "Default"),
        // The guards are SUSPENDED at T5 — one video in the folder cannot cross-attach.
        .init("adjacent episode attaches when it is the only video",
              video: "[Group] Show [01][1080p].mkv", sub: "[Group] Show [02][1080p].chs.ass",
              lonely: true, expected: "chs"),
    ]

    @Test("T5 — lonely-video fallback", arguments: lonelyVideo)
    func lonelyVideoTier(_ testCase: Case) { verify(testCase) }
}

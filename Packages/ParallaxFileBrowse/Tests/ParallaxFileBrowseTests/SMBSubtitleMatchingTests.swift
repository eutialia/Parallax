import Foundation
import Testing

/// Which subtitle files on a share go with which video, and under what label. Each case lists
/// one video and one subtitle file; `Decoy.mkv` beside them makes it a folder of several videos,
/// where a subtitle must prove it belongs.
@Suite("Subtitle files beside a video on a share")
struct SMBSubtitleMatchingTests {

    struct Pair: Sendable, CustomTestStringConvertible {
        let video: String
        let subtitle: String
        /// The label it attaches under, nil when it must not attach.
        let label: String?

        init(_ video: String, _ subtitle: String, _ label: String?) {
            self.video = video
            self.subtitle = subtitle
            self.label = label
        }

        var testDescription: String { "\(subtitle) beside \(video)" }
    }

    private func attached(_ pair: Pair, beside others: [String]) async throws -> [String: String] {
        let listing = ([pair.video, pair.subtitle] + others).map { SMBEntry.file($0) }
        let matches = try await makeSubtitleResolver(listing).subtitles(for: pair.video, in: "Movies")
        return Dictionary(uniqueKeysWithValues: matches.map { ($0.url.lastPathComponent, $0.label) })
    }

    private func expected(_ pair: Pair) -> [String: String] {
        pair.label.map { [pair.subtitle: $0] } ?? [:]
    }

    static let seasonFolder: [Pair] = [
        .init("[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].JPTC.ass", "jptc"),
        .init("[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              "[Nekomoe kissaten] Soredemo Ayumu wa Yosetekuru [01].JPTC.ass", "jptc"),
        .init("[Group] Bocchi the Rock! [01][Ma10p_1080p][abcd1234].mkv",
              "[Group] Bocchi the Rock! [01][Ma10p_1080p][ef567890].CHT.ass", "cht"),
        .init("[SubsPlease] Kanojo - 01 (1080p) [9A2B3C4D].mkv",
              "[Erai-raws] Kanojo - 01 [Multiple Subtitle][1080p][AABBCCDD].ass", "erai-raws"),
        .init("[Group] Show [05][1080p][abcd1234].mkv", "[Group] Show [05][720p].ass", "ep5"),
        .init("[Erai-raws] Spy x Family - 12 [1080p][ABCD1234].mkv",
              "[Erai-raws] Spy x Family - 12 [1080p][ABCD1234][CHS&CHT].ass", "chs.cht"),
        .init("[VCB-Studio] Violet Evergarden [01][Hi10p_1080p][x264_flac].mkv",
              "[VCB-Studio] Violet Evergarden [01][Hi10p_1080p][x264_flac][sc_jp].ass", "sc.jp"),
        .init("[Nekomoe] Lycoris Recoil [01v2][1080p].mkv", "[Nekomoe] Lycoris Recoil [01][1080p].JPTC.ass", "jptc"),
        .init("[Group] Show [05][1080p].mkv", "05.JPSC.ass", "jpsc"),
        .init("Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", "Show.Name.S01E02.en.srt", "en"),
        .init("Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", "Show.Name.S01E02.720p.HDTV.x264-OTHER.en.srt", "en"),
        .init("Breaking.Bad.1x05.HDTV.mkv", "Breaking.Bad.1x05.eng.srt", "eng"),
        .init("Show EP05 1080p.mkv", "Show EP05 720p.en.srt", "en"),
        .init("Apollo 13 - 3 [1080p].mkv", "Apollo 13 - 03.JPTC.ass", "jptc"),
        .init("[Grp] Show - 12-13 [1080p].mkv", "[Grp] Show - 12-13.JPTC.ass", "jptc"),
        .init("[Group] Show [01][1080p].mkv", "[Group] Show [01][1080p].sample.srt", "sample"),
        .init("[Group] Some OVA Special.mkv", "[Group] Some OVA Special.zh-Hans.ass", "zh-hans"),
        .init("[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [01][Ma10p_1080p][x265_flac].mkv",
              "[Nekomoe kissaten&VCB-Studio] Soredemo Ayumu wa Yosetekuru [02][Ma10p_1080p][x265_flac].JPTC.ass", nil),
        .init("[Group] Show [05][1080p].mkv", "06.JPSC.ass", nil),
        .init("[Group] Show A [01][1080p].mkv", "[Group] Show B [01][1080p].chs.ass", nil),
        .init("[SubsPlease] Frieren - 01 (1080p) [11223344].mkv", "[SubsPlease] Frieren - 02 (1080p) [55667788].srt", nil),
        .init("Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", "Show.Name.S01E03.en.srt", nil),
        .init("Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv", "Show.Name.S02E02.en.srt", nil),
        .init("[Group] Anime [05][1080p].mkv", "[Group] Anime NCED [1080p].ass", nil),
        .init("[Group] Anime [05][1080p].mkv", "[Group] Anime OP [1080p].srt", nil),
        .init("[Group] Anime [05][1080p].mkv", "[Group] Anime [05] NCED [1080p].ass", nil),
        .init("[Grp] Show - 12-13 [1080p].mkv", "[Grp] Show - 14-15.JPTC.ass", nil),
        .init("Show.Name.S01E01.1080p.mkv", "english.srt", nil),
    ]

    @Test("in a season folder a subtitle attaches to its own episode only, across drifted release tags, labelled by its language, else its release group, else its episode",
          arguments: seasonFolder)
    func seasonFolderSubtitle(_ pair: Pair) async throws {
        #expect(try await attached(pair, beside: ["Decoy.mkv"]) == expected(pair))
    }

    static let movieFolder: [Pair] = [
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2021.srt", "Default"),
        .init("TheMovie.CD1.avi", "TheMovie.CD1.eng.srt", "eng"),
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2021.en-GB.srt", "en-gb"),
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2021.zh-Hant.srt", "zh-hant"),
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2021.pt-BR.srt", "pt-br"),
        .init("Movie.mkv", "Movie-EN.srt", "en"),
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2021.gb.srt", "gb"),
        .init("Movie.mkv", "Movie2.srt", nil),
        .init("Movie.mkv", "MovieExtra.en.srt", nil),
        .init("Movie.mkv", "OtherMovie.srt", nil),
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2019.eng.srt", nil),
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2.2021.srt", nil),
        .init("Movie 7.mkv", "Movie.eng.srt", nil),
        .init("Movie VII.mkv", "Movie.eng.srt", nil),
        .init("TheMovie.CD1.avi", "TheMovie.CD2.srt", nil),
        .init("The.Long.Movie.Title.CD1.avi", "The.Long.Movie.Title.CD2.srt", nil),
        .init("Movie.Title.2021.1080p.BluRay.x264.mkv", "Movie.Title.2021.sample.srt", nil),
    ]

    @Test("in a movie folder a subtitle attaches across drifted quality tags, never across a different year, sequel, disc or title, and a region or script tag stays one language label",
          arguments: movieFolder)
    func movieFolderSubtitle(_ pair: Pair) async throws {
        #expect(try await attached(pair, beside: ["Decoy.mkv"]) == expected(pair))
    }

    static let titleWords: [Pair] = [
        .init("Man.on.Fire.2004.1080p.mkv", "Man.on.Fire.2004.srt", "Default"),
        .init("The.So-So.Years.2019.1080p.mkv", "The.So-So.Years.2019.srt", "Default"),
        .init("The.So-So.Years.2019.1080p.mkv", "The.So-So.Years.2019.en.srt", "en"),
    ]

    @Test("a title word that is also a language code stays part of the title", arguments: titleWords)
    func titleWordIsNotALanguage(_ pair: Pair) async throws {
        #expect(try await attached(pair, beside: ["Decoy.mkv"]) == expected(pair))
    }

    static let oneVideo: [Pair] = [
        .init("[OnlyVid] Standalone Film [BD_1080p].mkv", "random_subtitle_dump.ass", "Default"),
        .init("TheOnlyMovieHere.1080p.x265.mkv", "english_subs_final.srt", "english"),
        .init("Random.Fansub.Episode.Name.mkv", "different-translator-release.srt", "Default"),
        .init("[Group] Show [01][1080p].mkv", "[Group] Show [02][1080p].chs.ass", "chs"),
        .init("TheOnlyMovieHere.1080p.x265.mkv", "subtitle.en-GB.srt", "en-gb"),
    ]

    @Test("with one video in the folder, a subtitle beside it attaches whatever its name, labelled by its language, else Default",
          arguments: oneVideo)
    func oneVideoFolderSubtitle(_ pair: Pair) async throws {
        #expect(try await attached(pair, beside: []) == expected(pair))
    }
}

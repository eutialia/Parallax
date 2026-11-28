import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxFileBrowse

/// Release names as shares hold them, at `SMBSubtitleResolver.subtitles(for:in:)`.
@Suite("Subtitle files matched by name")
struct SMBSubtitleResolverProperties {

    private static let cases = 300
    private static let subtitleExtensions = ["srt", "ass", "ssa", "vtt"]
    private static let videoExtensions = ["mkv", "mp4", "avi", "m4v"]
    private static let words = ["Heat", "the", "Long", "Night", "Ran", "Kite", "Ocean", "Paper", "Moon", "Hotel", "Blue", "Echo"]
    private static let noise = ["1080p", "720p", "2160p", "x264", "x265", "HEVC", "WEB-DL", "BluRay", "AAC", "FLAC", "10bit", "Hi10p"]
    private static let groups = ["[Nekomoe]", "[SubsPlease]", "[VCB-Studio]", "[Erai-raws]", "[Grp]"]

    private static func mixedCase(_ text: String, _ random: inout SeededGenerator) -> String {
        String(text.map { Bool.random(using: &random) ? Character($0.uppercased()) : Character($0.lowercased()) })
    }

    private static func title(_ random: inout SeededGenerator) -> String {
        (0..<Int.random(in: 1...4, using: &random)).map { _ in words.randomElement(using: &random)! }
            .joined(separator: [".", " ", "_"].randomElement(using: &random)!)
    }

    private static func listing(_ names: [String]) -> [SMBDirectoryEntry] {
        names.map { SMBDirectoryEntry(name: $0, isDirectory: false, size: 1, modifiedAt: nil) }
    }

    private static func labels(for video: String, in names: [String]) async throws -> [String: String] {
        let matches = try await makeSubtitleResolver(listing(names)).subtitles(for: video, in: "Movies")
        return Dictionary(uniqueKeysWithValues: matches.map { ($0.url.lastPathComponent, $0.label) })
    }

    @Test("a subtitle named for the video is Default, and one named for it plus a tag is labelled by that tag, whatever the letter case or extension")
    func namedForTheVideo() async throws {
        var random = SeededGenerator(seed: 0x74_3132)
        for run in 0..<Self.cases {
            let stem = Self.title(&random) + "." + Self.noise.randomElement(using: &random)!
            let video = "\(stem).\(Self.videoExtensions.randomElement(using: &random)!)"
            let tag = (0..<Int.random(in: 1...3, using: &random))
                .map { _ in ["en", "forced", "JPTC", "zh-Hans", "sdh", "Signs Songs", "v2", "chs_cht"].randomElement(using: &random)! }
                .joined(separator: ".")
            let ext = { (random: inout SeededGenerator) in Self.subtitleExtensions.randomElement(using: &random)! }
            let plain = "\(Self.mixedCase(stem, &random)).\(ext(&random))"
            let tagged = "\(Self.mixedCase(stem, &random)).\(tag).\(ext(&random))"
            let emptyTag = "\(stem)..\(ext(&random))"

            let labels = try await Self.labels(for: video, in: [video, "Decoy.mkv", plain, tagged, emptyTag])

            #expect(labels == [plain: "Default", tagged: tag.lowercased()], "run \(run): \(video)")
        }
    }

    @Test("with one video in the folder, every subtitle file beside it attaches")
    func oneVideoTakesEverySubtitle() async throws {
        var random = SeededGenerator(seed: 0x6C_6F6E65)
        for run in 0..<Self.cases {
            let video = "\(Self.title(&random)).\(Self.videoExtensions.randomElement(using: &random)!)"
            let subtitles = Set((0..<Int.random(in: 1...6, using: &random)).map { _ in
                [Self.groups.randomElement(using: &random)!, Self.title(&random), String(Int.random(in: 1...99, using: &random)),
                 Self.noise.randomElement(using: &random)!].shuffled(using: &random).joined(separator: " ")
                    + ".\(Self.subtitleExtensions.randomElement(using: &random)!)"
            })

            let labels = try await Self.labels(for: video, in: [video] + subtitles.sorted() + ["notes.txt", "cover.jpg"])

            #expect(Set(labels.keys) == subtitles, "run \(run): \(video)")
        }
    }

    /// Episode numbers share one width, so no episode's name is another's plus a dot tag.
    @Test("in a season folder each episode's subtitle attaches to that episode only, across drifted release tags")
    func episodesKeepTheirOwnSubtitles() async throws {
        var random = SeededGenerator(seed: 0x65_7069)
        let forms: [(Int, Int) -> String] = [
            { season, episode in String(format: "S%02dE%02d", season, episode) },
            { _, episode in String(format: "[%02d]", episode) },
            { _, episode in String(format: " - %02d ", episode) },
            { _, episode in String(format: "EP%02d", episode) },
            { season, episode in String(format: "%dx%02d", season, episode) },
        ]
        for run in 0..<Self.cases {
            let form = forms.randomElement(using: &random)!
            let season = Int.random(in: 1...9, using: &random)
            let title = Self.title(&random)
            let group = Self.groups.randomElement(using: &random)!
            let episodes = Array(Set((0..<Int.random(in: 2...6, using: &random)).map { _ in Int.random(in: 1...24, using: &random) }))
            let name = { (episode: Int, tags: [String]) in
                "\(group) \(title) \(form(season, episode)) " + tags.map { "[\($0)]" }.joined()
            }
            let pairs = episodes.map { episode in
                let videoTags = Array(Self.noise.shuffled(using: &random).prefix(Int.random(in: 1...3, using: &random)))
                let subtitleTags = Array(Self.noise.shuffled(using: &random).prefix(Int.random(in: 0...2, using: &random)))
                let language = ["en", "chs", "JPTC", "eng"].randomElement(using: &random)!
                return (video: name(episode, videoTags) + ".mkv",
                        subtitle: name(episode, subtitleTags) + ".\(language).\(Self.subtitleExtensions.randomElement(using: &random)!)")
            }
            let folder = pairs.flatMap { [$0.video, $0.subtitle] }

            for pair in pairs {
                let labels = try await Self.labels(for: pair.video, in: folder)
                #expect(Array(labels.keys) == [pair.subtitle], "run \(run): \(pair.video) in \(folder)")
            }
        }
    }
}

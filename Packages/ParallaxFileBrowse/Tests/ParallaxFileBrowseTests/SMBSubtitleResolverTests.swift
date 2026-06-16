import Foundation
import Testing
@testable import ParallaxFileBrowse

@Suite("SMBSubtitleResolver")
struct SMBSubtitleResolverTests {

    // MARK: - Helpers

    private func makeResolver(entries: [SMBDirectoryEntry]) -> SMBSubtitleResolver {
        let lister = FakeSMBLister(entries: entries)
        return SMBSubtitleResolver(lister: lister, host: "nas", share: "Media", root: "Movies")
    }

    // MARK: - Basic match

    @Test("Returns all subtitle siblings with correct labels")
    func basicMatch() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie.mkv",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.srt",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.en.srt", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.ass",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.ssa",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.vtt",    isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")

        #expect(matches.count == 5)

        let byURL = Dictionary(uniqueKeysWithValues: matches.map { ($0.url.lastPathComponent, $0.label) })
        #expect(byURL["Movie.srt"]    == "Default")
        #expect(byURL["Movie.en.srt"] == "en")
        #expect(byURL["Movie.ass"]    == "Default")
        #expect(byURL["Movie.ssa"]    == "Default")
        #expect(byURL["Movie.vtt"]    == "Default")
    }

    // MARK: - Unrelated names ignored

    @Test("Unrelated filenames are not returned")
    func unrelatedIgnored() async throws {
        // Two videos present → lonelyVideo is false for a real reason (a multi-movie folder), so the
        // strict reject path is genuinely exercised. (With zero videos the count is also 0, but then
        // the assertion would be vacuous — a single present video flips on the lonely fallback.)
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie.mkv",      isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Decoy.mkv",      isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "OtherMovie.srt", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie2.srt",     isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "readme.txt",     isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "poster.jpg",     isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Trailer.en.srt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.isEmpty)
    }

    // MARK: - Case-insensitive match

    @Test("Match is case-insensitive; label is lowercased")
    func caseInsensitive() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "movie.EN.srt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].label == "en")
    }

    // MARK: - Multi-token language tag

    @Test("Multi-token language tag becomes the full middle label")
    func multiTokenLanguage() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie.en.forced.srt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].label == "en.forced")
    }

    // MARK: - Directories excluded

    @Test("Directory entry named like a subtitle is ignored")
    func directoryExcluded() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie.srt", isDirectory: true,  size: 0, modifiedAt: nil),
            .init(name: "Movie.vtt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].url.lastPathComponent == "Movie.vtt")
        #expect(matches[0].label == "Default")
    }

    // MARK: - Edge cases

    @Test("A video name with no extension still matches its siblings")
    func noExtensionVideoName() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie.srt",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.en.srt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie", in: "Movies")
        #expect(matches.count == 2)
        #expect(Set(matches.map(\.label)) == ["Default", "en"])
    }

    @Test("An empty language token (double-dot stem) is rejected in a multi-video folder")
    func emptyLanguageTokenRejected() async throws {
        // Multi-video folder (lonelyVideo == false) so the malformed empty-suffix sidecar is rejected.
        // In a lonely-video folder it would instead attach via T5 — a separate, intended behavior.
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie.mkv",  isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Decoy.mkv",  isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie..srt", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.srt",  isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].url.lastPathComponent == "Movie.srt")
    }

    // MARK: - URL shape

    @Test("URL contains no credentials and has correct smb:// shape")
    func urlShape() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie.en.srt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let lister = FakeSMBLister(entries: entries)
        let resolver = SMBSubtitleResolver(lister: lister, host: "192.168.1.10", share: "Media", root: "")
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.count == 1)
        let raw = matches[0].url.absoluteString
        #expect(!raw.contains("@"), "URL must not contain credential separator '@'")
        #expect(raw == "smb://192.168.1.10/Media/Movies/Movie.en.srt")
    }

    // MARK: - Prefix-collision guard

    @Test("Prefix-only matches are rejected — Movie2.srt must not match Movie.mkv")
    func prefixCollisionRejected() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Movie2.srt",          isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "MovieExtra.en.srt",   isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.srt",           isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].url.lastPathComponent == "Movie.srt")
    }

    // MARK: - Loosened matching (end-to-end through the resolver)

    @Test("Season folder: only the resolved episode's subtitle is returned, never a sibling episode's")
    func seasonFolderEpisodeIsolation() async throws {
        // Two videos in the directory → lonely-video fallback disabled → the episode guard rules.
        let entries: [SMBDirectoryEntry] = [
            .init(name: "[Grp] Show [01][1080p].mkv",     isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "[Grp] Show [02][1080p].mkv",     isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "[Grp] Show [01][1080p].chs.ass", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "[Grp] Show [02][1080p].chs.ass", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "[Grp] Show [01][1080p].mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].label == "chs")
        #expect(matches[0].url.lastPathComponent.contains("[01]"))
        #expect(!matches[0].url.lastPathComponent.contains("[02]"))
    }

    @Test("Drifted release of the same episode matches across groups/tags (T3)")
    func driftedReleaseMatches() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "[GroupA] Frieren - 05 [1080p][AAAA1111].mkv", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "[GroupB] Frieren - 05 [720p].JPTC.ass",       isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "[GroupA] Frieren - 06 [1080p][BBBB2222].mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "[GroupA] Frieren - 05 [1080p][AAAA1111].mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].label == "jptc")
    }

    @Test("Lonely video: a single video in the folder attaches an arbitrarily-named subtitle")
    func lonelyVideoAttachesArbitrarySub() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Standalone.Film.1080p.mkv", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "some_random_subs.srt",      isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let resolver = makeResolver(entries: entries)
        let matches = try await resolver.subtitles(for: "Standalone.Film.1080p.mkv", in: "Movies")
        #expect(matches.count == 1)
        #expect(matches[0].label == "Default")
    }
}

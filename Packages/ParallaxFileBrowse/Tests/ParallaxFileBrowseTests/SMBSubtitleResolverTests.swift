import Foundation
import Testing
@testable import ParallaxFileBrowse

/// The resolver owns the SMB side only — directory filtering, the lonely-video count, URL shape.
/// Label semantics belong to `SubtitleMatcherTests`, which drives the matcher directly; duplicating
/// its rows here just moved the same matrix one layer up.
@Suite("SMBSubtitleResolver")
struct SMBSubtitleResolverTests {

    @Test("every subtitle-extension sibling of the video is returned")
    func returnsEverySubtitleSibling() async throws {
        let subtitles = ["Movie.srt", "Movie.ass", "Movie.ssa", "Movie.vtt", "Movie.en.srt"]
            .map { SMBEntry.file($0) }
        // A second video keeps the lonely-video fallback off, so these attach on their own merits.
        let videos = [SMBEntry.file("Movie.mkv"), SMBEntry.file("Decoy.mkv")]

        let matches = try await makeSubtitleResolver(videos + subtitles)
            .subtitles(for: "Movie.mkv", in: "Movies")

        #expect(Set(matches.map(\.url.lastPathComponent)) == Set(subtitles.map(\.name)))
    }

    /// `.sub` is deliberately out of scope (it needs a sibling `.idx`), and non-subtitle siblings
    /// must never be offered as tracks.
    @Test("non-subtitle siblings are never returned", arguments: ["Movie.sub", "Movie.txt", "Movie.nfo", "Movie.jpg"])
    func nonSubtitleExtensionsIgnored(_ name: String) async throws {
        let matches = try await makeSubtitleResolver([SMBEntry.file("Movie.mkv"), SMBEntry.file(name)])
            .subtitles(for: "Movie.mkv", in: "Movies")
        #expect(matches.isEmpty)
    }

    @Test("a directory named like a subtitle is skipped")
    func directoryExcluded() async throws {
        let matches = try await makeSubtitleResolver([
            SMBEntry.dir("Movie.srt"),
            SMBEntry.file("Movie.vtt"),
        ]).subtitles(for: "Movie.mkv", in: "Movies")

        #expect(matches.map(\.url.lastPathComponent) == ["Movie.vtt"])
    }

    @Test("in a multi-video folder an unrelated subtitle attaches to nobody")
    func unrelatedIgnoredInAMultiVideoFolder() async throws {
        // Two videos → the lonely-video fallback is off, so the strict reject path is what runs.
        let matches = try await makeSubtitleResolver([
            SMBEntry.file("Movie.mkv"),
            SMBEntry.file("Decoy.mkv"),
            SMBEntry.file("OtherMovie.srt"),
            SMBEntry.file("Trailer.en.srt"),
        ]).subtitles(for: "Movie.mkv", in: "Movies")

        #expect(matches.isEmpty)
    }

    /// The count that switches the fallback on is per media-typed entry, and it deliberately counts
    /// zero-byte stubs too: a stub beside one real video reads as two videos, keeping the loose
    /// cross-attach OFF rather than letting a grid concern flip subtitle matching.
    @Test("the lonely-video fallback keys off the video count, stubs included")
    func lonelyVideoFallbackCountsStubs() async throws {
        let lonely = try await makeSubtitleResolver([
            SMBEntry.file("Standalone.Film.1080p.mkv"),
            SMBEntry.file("some_random_subs.srt"),
        ]).subtitles(for: "Standalone.Film.1080p.mkv", in: "Movies")
        #expect(lonely.map(\.label) == ["Default"], "one video → any sibling subtitle attaches")

        let withStub = try await makeSubtitleResolver([
            SMBEntry.file("Standalone.Film.1080p.mkv"),
            SMBEntry.file("Interrupted.mkv", size: 0),
            SMBEntry.file("some_random_subs.srt"),
        ]).subtitles(for: "Standalone.Film.1080p.mkv", in: "Movies")
        #expect(withStub.isEmpty, "a zero-byte stub still counts as a video — no loose attach")
    }

    @Test("a season folder returns only the requested episode's subtitle")
    func seasonFolderEpisodeIsolation() async throws {
        let matches = try await makeSubtitleResolver([
            SMBEntry.file("[Grp] Show [01][1080p].mkv"),
            SMBEntry.file("[Grp] Show [02][1080p].mkv"),
            SMBEntry.file("[Grp] Show [01][1080p].chs.ass"),
            SMBEntry.file("[Grp] Show [02][1080p].chs.ass"),
        ]).subtitles(for: "[Grp] Show [01][1080p].mkv", in: "Movies")

        #expect(matches.map(\.url.lastPathComponent) == ["[Grp] Show [01][1080p].chs.ass"])
        #expect(matches.map(\.label) == ["chs"])
    }

    @Test("returned URLs are credential-free smb://host/share/dir/name")
    func urlShape() async throws {
        let resolver = makeSubtitleResolver([SMBEntry.file("Movie.en.srt")], host: "192.168.1.10", root: "")
        let matches = try await resolver.subtitles(for: "Movie.mkv", in: "Movies")

        let url = try #require(matches.first?.url)
        #expect(url.absoluteString == "smb://192.168.1.10/Media/Movies/Movie.en.srt")
        #expect(url.absoluteString.contains("@") == false, "credentials are never embedded")
    }

    /// A hostile host/name still percent-encodes into a usable URL, so every matched sibling is
    /// returned — the resolver's "drop the one entry whose URL wouldn't build" guard is defensive.
    @Test("a hostile host and filename still yield a usable subtitle URL")
    func hostileNamesStillBuildURLs() async throws {
        let resolver = makeSubtitleResolver([SMBEntry.file("Movie#1?.srt")], host: "Living Room NAS", root: "")
        let matches = try await resolver.subtitles(for: "Movie#1?.mkv", in: "Movies")

        let url = try #require(matches.first?.url)
        #expect(url.lastPathComponent == "Movie#1?.srt")
        #expect(url.host(percentEncoded: false) == "Living Room NAS")
    }
}

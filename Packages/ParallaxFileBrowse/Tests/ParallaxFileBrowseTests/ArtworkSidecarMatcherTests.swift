import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Drives the strict sidecar-artwork matcher directly (no lister/I-O), one assertion per case.
/// `expected == nil` means "must not match"; otherwise it is the exact image filename chosen.
@Suite("ArtworkSidecarMatcher")
struct ArtworkSidecarMatcherTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let video: String
        let images: [String]
        let expected: String?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // ---- Tier order: -thumb > -poster > bare stem ----
        .init(name: "bare same-stem matches", video: "Film.mkv", images: ["Film.jpg"], expected: "Film.jpg"),
        .init(name: "-thumb wins over bare", video: "Film.mkv",
              images: ["Film.jpg", "Film-thumb.png"], expected: "Film-thumb.png"),
        .init(name: "-poster wins over bare", video: "Film.mkv",
              images: ["Film.jpg", "Film-poster.png"], expected: "Film-poster.png"),
        .init(name: "-thumb wins over -poster", video: "Film.mkv",
              images: ["Film-poster.jpg", "Film-thumb.jpg"], expected: "Film-thumb.jpg"),

        // ---- Case-insensitive on the stem, extension-agnostic ----
        .init(name: "case-insensitive stem", video: "Film.MKV", images: ["film.JPG"], expected: "film.JPG"),
        .init(name: "heic accepted", video: "Film.mkv", images: ["Film.heic"], expected: "Film.heic"),
        .init(name: "webp accepted", video: "Film.mkv", images: ["Film.webp"], expected: "Film.webp"),

        // ---- Strictness: no fuzz, no folder art, no cross-attach ----
        .init(name: "folder.jpg never attaches", video: "Film.mkv",
              images: ["folder.jpg"], expected: nil),
        .init(name: "poster.jpg (no stem) never attaches", video: "Film.mkv",
              images: ["poster.jpg"], expected: nil),
        .init(name: "different episode stem rejected", video: "Show - 01.mkv",
              images: ["Show - 02.jpg"], expected: nil),
        .init(name: "prefix-only stem rejected", video: "Film.mkv",
              images: ["Film 2.jpg"], expected: nil),
        .init(name: "sequel stem rejected", video: "Film.mkv",
              images: ["Film2.jpg"], expected: nil),
        .init(name: "non-image sibling ignored", video: "Film.mkv",
              images: ["Film.txt", "Film.nfo"], expected: nil),
        .init(name: "no images → no match", video: "Film.mkv", images: [], expected: nil),

        // ---- Deterministic tie-break within a tier (lexicographically-first filename) ----
        .init(name: "same-stem multi-ext → lexicographically first", video: "Film.mkv",
              images: ["Film.png", "Film.jpg"], expected: "Film.jpg"),

        // ---- Multi-video folder: each stem picks its own, no bleed ----
        .init(name: "picks the matching episode's art", video: "Show - 03.mkv",
              images: ["Show - 01.jpg", "Show - 03.jpg", "Show - 02.jpg"], expected: "Show - 03.jpg"),
    ]

    @Test("sidecar match matrix", arguments: cases)
    func matches(_ c: Case) {
        #expect(ArtworkSidecarMatcher.match(videoName: c.video, in: .init(imageNames: c.images)) == c.expected)
    }

    @Test("isImageFile accepts the allowlist, rejects video/subtitle/text")
    func isImageFileAllowlist() {
        for ext in ArtworkSidecarMatcher.imageExtensions {
            #expect(ArtworkSidecarMatcher.isImageFile(name: "x.\(ext)"))
            #expect(ArtworkSidecarMatcher.isImageFile(name: "x.\(ext.uppercased())"))
        }
        for ext in ["mkv", "srt", "txt", "nfo", ""] {
            #expect(!ArtworkSidecarMatcher.isImageFile(name: "x.\(ext)"))
        }
    }
}

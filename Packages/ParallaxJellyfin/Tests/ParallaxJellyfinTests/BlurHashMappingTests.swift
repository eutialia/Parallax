import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

/// The server ships BlurHashes as 13 SEPARATE per-image-type dictionaries, while the domain models
/// store artwork identity by TAG. Flattening on the tag is what lets `imageRef(_:)` attach
/// `blurHashes[tag]` without re-deriving which image type a tag belonged to — and it makes indexed
/// backdrops work for free, since each backdrop image has its own tag.
@Suite("BlurHash flattening")
struct BlurHashMappingTests {
    @Test("Hashes from every image type collapse into one tag-keyed map")
    func flattensAcrossImageTypes() {
        var dto = JellyfinFixtures.movieDto(id: "m1")
        dto.imageBlurHashes = ImageBlurHashes(
            art: ["art-tag": "AAAA"],
            // Two backdrops, each with its own tag: both must survive as separate entries, which
            // is what makes `imageRef(.backdrop(index:))` resolvable per image.
            backdrop: ["bd-0": "BBBB", "bd-1": "CCCC"],
            banner: ["banner-tag": "DDDD"],
            logo: ["logo-tag": "EEEE"],
            primary: ["primary-tag": "FFFF"],
            thumb: ["thumb-tag": "GGGG"]
        )

        #expect(dto.tagBlurHashes == [
            ImageTag(rawValue: "art-tag"): "AAAA",
            ImageTag(rawValue: "bd-0"): "BBBB",
            ImageTag(rawValue: "bd-1"): "CCCC",
            ImageTag(rawValue: "banner-tag"): "DDDD",
            ImageTag(rawValue: "logo-tag"): "EEEE",
            ImageTag(rawValue: "primary-tag"): "FFFF",
            ImageTag(rawValue: "thumb-tag"): "GGGG",
        ])
    }

    /// Most items carry no BlurHashes at all (the server only computes them when configured), and an
    /// item with the container present but every type nil is just as common.
    @Test("An absent or empty hash payload yields an empty map, not a crash")
    func absentHashes() {
        var dto = JellyfinFixtures.movieDto(id: "m1")
        #expect(dto.tagBlurHashes.isEmpty, "no imageBlurHashes at all")

        dto.imageBlurHashes = ImageBlurHashes()
        #expect(dto.tagBlurHashes.isEmpty, "a container with every image type nil")
    }

    /// The whole point of the flattening: a mapped model can hand its `imageRef` a blur without the
    /// call site knowing which per-type dictionary the hash came from.
    @Test("A mapped model's imageRef carries the blur for its own tag")
    func mappedModelCarriesBlurHash() throws {
        var dto = JellyfinFixtures.movieDto(id: "m1")
        dto.imageTags = ["Primary": "primary-tag", "Logo": "logo-tag"]
        dto.imageBlurHashes = ImageBlurHashes(
            logo: ["logo-tag": "LLLL"],
            primary: ["primary-tag": "PPPP"]
        )

        let movie = try #require(dto.toMovie())
        #expect(movie.imageRef(.primary)?.blurHash == "PPPP")
        #expect(movie.imageRef(.logo)?.blurHash == "LLLL")
    }

    /// Tags are content-hash-derived and don't collide across image types in practice; if they ever
    /// did, the map must still resolve to ONE hash rather than losing the entry — both hashes
    /// describe near-identical bytes, so either is an acceptable placeholder.
    @Test("A tag that appears under two image types still resolves to one hash")
    func collidingTagResolves() {
        var dto = JellyfinFixtures.movieDto(id: "m1")
        dto.imageBlurHashes = ImageBlurHashes(
            logo: ["shared-tag": "LLLL"],
            primary: ["shared-tag": "PPPP"]
        )
        let hashes = dto.tagBlurHashes
        #expect(hashes.count == 1)
        #expect(["LLLL", "PPPP"].contains(hashes[ImageTag(rawValue: "shared-tag")] ?? ""))
    }
}

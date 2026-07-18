import Foundation
import JellyfinAPI
import ParallaxCore

extension BaseItemDto {
    /// Flattens Jellyfin's per-image-type BlurHash dictionaries into ONE tag-keyed map, matching
    /// how our domain models store artwork identity (by `ImageTag`, not by image type).
    ///
    /// The server ships `imageBlurHashes` as 13 optional `[tag: hash]` dictionaries — one per image
    /// type (primary, backdrop, thumb, logo, …). Our `imageRef(_:)` already resolves an `ImageKind`
    /// to a single tag, so keying the flat map by tag lets the model attach `blurHashes[tag]` without
    /// re-deriving which type a tag belonged to. That also handles indexed backdrops for free: each
    /// backdrop image has its own tag, so each lands as its own entry.
    ///
    /// Tags are content-hash-derived and don't collide across image types in practice; on the
    /// vanishingly rare collision the later `merge` winner is an acceptable choice — both hashes
    /// describe near-identical artwork bytes, so the placeholder blur is indistinguishable either way.
    var tagBlurHashes: [ImageTag: String] {
        guard let hashes = imageBlurHashes else { return [:] }
        let perType: [[String: String]?] = [
            hashes.art, hashes.backdrop, hashes.banner, hashes.box, hashes.boxRear,
            hashes.chapter, hashes.disc, hashes.logo, hashes.menu, hashes.primary,
            hashes.profile, hashes.screenshot, hashes.thumb,
        ]
        var result: [ImageTag: String] = [:]
        for dict in perType.compactMap({ $0 }) {
            for (tag, hash) in dict {
                result[ImageTag(rawValue: tag)] = hash
            }
        }
        return result
    }
}

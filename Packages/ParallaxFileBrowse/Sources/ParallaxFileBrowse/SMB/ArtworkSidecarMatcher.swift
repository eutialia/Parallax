import Foundation

/// Transport-agnostic sidecar-ARTWORK filename matching for a browsed video.
///
/// Pure value logic — no I/O, no SMB types — so it is unit-testable in isolation and reusable for
/// any sidecar-image source (SMB today, local files later). `SMBFileSource.browse` owns the
/// listing side and delegates every name decision here.
///
/// ## Why this is DELIBERATELY strict — the opposite of `SubtitleMatcher`
/// `SubtitleMatcher` loosens matching to tolerate release-tag drift, because a *missing* subtitle is
/// a real loss and a mislabeled-but-correct sub is still usable. Artwork is the reverse: a poster is
/// pure decoration, and painting the WRONG still on a tile actively misleads (an episode wearing a
/// different episode's frame, or every episode in a folder wearing the season's `folder.jpg`). So
/// this matcher has NO fuzziness: it accepts only an image whose stem is EXACTLY the video's stem,
/// optionally with a `-thumb`/`-poster` qualifier. No tag drift, no title overlap, no folder-level
/// art. Wrong art is worse than no art — a miss just falls through to the frame-grab pipeline.
///
/// ## Tier order (first hit wins; more specific qualifier first)
/// For a video whose stem is `S` (case-insensitive):
/// - **T1** `S-thumb.<ext>` — an explicit thumbnail beside the video
/// - **T2** `S-poster.<ext>` — an explicit poster beside the video
/// - **T3** `S.<ext>` — a bare same-stem image
///
/// `folder.jpg`/`poster.jpg` with no matching video stem never match — that is the *folder's* art,
/// not any single episode's, so it is intentionally invisible here.
enum ArtworkSidecarMatcher {

    /// Recognised sidecar image extensions (lowercased). ImageIO decodes all of these via
    /// `ImageTranscode.downscaledImage`; `webp` included since modern NAS scrapers emit it.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    /// True for a non-directory entry name whose extension is a recognised image type. The
    /// directory exclusion is the caller's (it holds the `isDirectory` flag); this is the name test,
    /// shared so the browse filter and any future caller agree on "is this a sidecar image".
    static func isImageFile(name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A prebuilt lookup from lowercased image STEM → chosen filename, built ONCE per directory
    /// listing so per-video matching is three dictionary probes instead of three linear scans of
    /// every image name (O(videos × images) on a flat NAS dump with thousands of each — a browse
    /// hot-path cost). Non-image names are ignored at build. A same-stem collision across
    /// extensions (`S.jpg` AND `S.png`) resolves to the lexicographically-first filename — a
    /// deterministic, arbitrary tie-break, not a meaningful preference (a folder with two
    /// identically stemmed posters is already pathological).
    struct Index {
        fileprivate let byStem: [String: String]

        init(imageNames: [String]) {
            var byStem: [String: String] = [:]
            for name in imageNames where ArtworkSidecarMatcher.isImageFile(name: name) {
                let stem = (name as NSString).deletingPathExtension.lowercased()
                if let existing = byStem[stem] {
                    if name < existing { byStem[stem] = name }
                } else {
                    byStem[stem] = name
                }
            }
            self.byStem = byStem
        }
    }

    /// The single best sidecar image filename for `videoName` in `index`, or nil when none
    /// qualifies. Matching is case-insensitive on the stem.
    static func match(videoName: String, in index: Index) -> String? {
        let stem = (videoName as NSString).deletingPathExtension.lowercased()
        guard !stem.isEmpty else { return nil }
        // Most-specific qualifier first; "" is the bare same-stem tier.
        for qualifier in ["-thumb", "-poster", ""] {
            if let hit = index.byStem[stem + qualifier] { return hit }
        }
        return nil
    }
}

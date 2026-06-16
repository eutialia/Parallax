import Foundation

// NOTE: `.sub` sidecar files are intentionally out of scope — they require a sibling `.idx`
// index file to function. Implement as a follow-up once the player can handle dual-file subs.

/// A subtitle file found alongside a video on an SMB share.
public struct SMBSubtitleMatch: Sendable, Hashable {
    /// Human-readable track label. A recovered language/qualifier tag (e.g. `"en"`, `"en.forced"`,
    /// `"jptc"`), the differing release group, an `"epNN"` anchor, or `"Default"` when nothing
    /// distinguishes the sub. Language tags are lowercased; `"Default"` is the literal fallback.
    public let label: String

    /// `smb://host/share/path/filename` — credentials are NEVER embedded.
    public let url: URL

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

/// Finds subtitle sidecar files for a video on an SMB share by comparing sibling filenames.
///
/// All filename-matching logic lives in `SubtitleMatcher` (pure, transport-agnostic, unit-tested in
/// isolation). This type owns only the SMB side: list one directory level, count videos to decide
/// the lonely-video fallback, then ask the matcher for each subtitle sibling's label.
///
/// Recognised subtitle extensions: `srt`, `ass`, `ssa`, `vtt`.
public struct SMBSubtitleResolver: Sendable {

    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    private let fileSource: SMBFileSource

    public init(lister: any SMBLister, host: String = "", share: String, root: String) {
        self.fileSource = SMBFileSource(lister: lister, host: host, share: share, root: root)
    }

    /// Returns subtitle matches for `videoName` found in `path` (one directory level only).
    ///
    /// - Parameters:
    ///   - videoName: Basename of the video file, e.g. `"Movie.mkv"`.
    ///   - path: Directory path relative to the configured root, e.g. `"Movies"`.
    public func subtitles(for videoName: String, in path: String) async throws -> [SMBSubtitleMatch] {
        // List once via SMBFileSource — allEntries rather than mediaFiles, since we need both the
        // subtitle siblings AND a video count, and reuse playableURL so path-building stays in one place.
        let allEntries = try await fileSource.allEntries(in: path)

        let video = SubtitleMatcher.NameModel(filename: videoName)

        // Lonely-video tier: enabled only when exactly one video file is present in this directory.
        // A many-video season folder disables the fallback so it can't cross-attach. Counted per raw
        // entry (a listing never repeats a name) — no case-folding, so two case-distinct videos read
        // as two, keeping the guard-suspending fallback off.
        let lonelyVideo = allEntries.lazy.filter(SMBFileSource.isMediaFile).count == 1

        var matches: [SMBSubtitleMatch] = []
        for entry in allEntries {
            guard !entry.isDirectory else { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            guard Self.subtitleExtensions.contains(ext) else { continue }

            let sub = SubtitleMatcher.NameModel(filename: entry.name)
            guard let label = SubtitleMatcher.label(forSub: sub, video: video, lonelyVideo: lonelyVideo) else { continue }

            // playableURL percent-encodes path components (SMBURL), so '#'/'?' siblings no
            // longer truncate; nil here means the components still couldn't form a URL. Drop
            // the one entry rather than aborting the whole scan.
            guard let url = fileSource.playableURL(for: entry, in: path) else { continue }
            matches.append(SMBSubtitleMatch(label: label, url: url))
        }
        return matches
    }
}

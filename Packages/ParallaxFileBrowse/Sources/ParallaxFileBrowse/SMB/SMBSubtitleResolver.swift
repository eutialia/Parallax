import Foundation

// NOTE: `.sub` sidecar files are intentionally out of scope — they require a sibling `.idx`
// index file to function. Implement as a follow-up once the player can handle dual-file subs.

/// A subtitle file found alongside a video on an SMB share.
public struct SMBSubtitleMatch: Sendable, Hashable {
    /// Human-readable track label. Language tag extracted from the filename (e.g. `"en"`,
    /// `"en.forced"`) or `"Default"` when the subtitle name exactly matches the video basename
    /// with no additional tokens. Always lowercased.
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
/// **Match rule:** a sibling is a subtitle match when its stem is either:
/// - exactly the video basename (→ label `"Default"`), or
/// - the video basename followed by `.` and one or more dot-separated tokens (→ label = those tokens).
///
/// The comparison is case-insensitive; the label is lowercased.
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
        let videoBasename = (videoName as NSString).deletingPathExtension.lowercased()

        // List once via SMBFileSource — allEntries rather than mediaFiles, which would filter to
        // video extensions — and reuse playableURL for the smb:// URLs so path-building stays in one place.
        let allEntries = try await fileSource.allEntries(in: path)

        var matches: [SMBSubtitleMatch] = []
        for entry in allEntries {
            guard !entry.isDirectory else { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            guard Self.subtitleExtensions.contains(ext) else { continue }

            let siblingBasename = (entry.name as NSString).deletingPathExtension.lowercased()

            let label: String
            if siblingBasename == videoBasename {
                // Exact match — no language token.
                label = "Default"
            } else if siblingBasename.hasPrefix(videoBasename + ".") {
                // Language token(s) after the video basename.
                let afterDot = String(siblingBasename.dropFirst(videoBasename.count + 1))
                guard !afterDot.isEmpty else { continue }
                label = afterDot
            } else {
                // Prefix-only or unrelated — skip.
                continue
            }

            // playableURL percent-encodes path components (SMBURL), so '#'/'?' siblings no
            // longer truncate; nil here means the components still couldn't form a URL. Drop
            // the one entry rather than aborting the whole scan.
            guard let url = fileSource.playableURL(for: entry, in: path) else { continue }
            matches.append(SMBSubtitleMatch(label: label, url: url))
        }
        return matches
    }
}

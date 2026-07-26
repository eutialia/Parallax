import Foundation

/// Builds the credential-free `smb://host/share/path` URL shared by directory browsing
/// (`SMBFileSource.playableURL`) and playback resolution (`SMBPlaybackResolver`).
///
/// Each component is percent-encoded so structural URL delimiters in real filenames don't
/// corrupt the URL. A name like `Episode#1.mkv` or `Show?.mkv` would otherwise have its
/// `#`/`?` parsed by `URL(string:)` as a fragment/query, silently TRUNCATING the path at the
/// delimiter (spaces, brackets and Unicode happen to auto-encode and survive, but `#`/`?` do
/// not). libVLC's RFC-3986 MRL parser decodes the encoding back to the literal path when it
/// opens the file — proven by the fact that auto-encoded spaces (`%20`) already play.
public enum SMBURL {
    /// Percent-encoding makes the construction TOTAL: every character that could break the parse
    /// is escaped first, so `URL(string:)` always succeeds and neither builder below is failable.
    /// Pinned by `SMBURLTests.hostOnlyAlwaysProducesAnSMBURL` / `makeAlwaysProducesAnSMBURL`
    /// (hostile hosts, shares and paths — delimiters, brackets, `%`, spaces, unicode, empty).
    ///
    /// - Parameters:
    ///   - host: bare host (no scheme/userinfo).
    ///   - share: share name.
    ///   - path: share-relative path with `/` separators; empty = the share root.
    /// - Returns: the encoded `smb://` URL.
    public static func make(host: String, share: String, path: String) -> URL {
        // `.urlPathAllowed` keeps `/` (so path separators survive) and ordinary name
        // characters, while encoding `#`, `?`, spaces, brackets, etc.
        let pathChars = CharacterSet.urlPathAllowed
        let encHost = encoded(host, allowing: .urlHostAllowed)
        let encShare = encoded(share, allowing: pathChars)
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encPath = encoded(trimmedPath, allowing: pathChars)
        let tail = encPath.isEmpty ? encShare : "\(encShare)/\(encPath)"
        return URL(string: "smb://\(encHost)/\(tail)")!
    }

    /// Scheme-only connection URL (`smb://host`, no share/path, no userinfo) — what
    /// `SMB2Manager` derives its connection target from. Percent-encodes the host so a
    /// Bonjour-synthesised name with a space (e.g. "My NAS.local") forms a real URL and
    /// attempts a resolve. ONE home for that encoding subtlety — `AMSMB2Lister` and
    /// `SMBConnectionTarget` both build their connection URL here.
    public static func hostOnly(_ host: String) -> URL {
        URL(string: "smb://\(encoded(host, allowing: .urlHostAllowed))")!
    }

    /// `addingPercentEncoding` is only documented to fail for a string the target encoding can't
    /// represent — impossible for a Swift `String` over UTF-8 — so the identity fallback is a
    /// formality, kept in one place instead of repeated at each component.
    private static func encoded(_ component: String, allowing allowed: CharacterSet) -> String {
        component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    /// Inverse of `make`: decodes an `smb://host/share/path` URL back into its parts.
    ///
    /// `URL.pathComponents` percent-decodes each component, so the literal share/path a
    /// caller needs to re-open the file (`SMBRandomAccessReader`) come back verbatim — the
    /// `Episode#1.mkv` / `Show?.mkv` names `make` encoded are restored, not re-truncated.
    /// The first path segment is the share; the rest (joined with `/`) is the share-relative
    /// path. Returns nil for a non-`smb` URL or one missing a share segment.
    /// - Returns: `(host, share, path)` where `path` is empty for a share-root URL.
    public static func parse(_ url: URL) -> (host: String, share: String, path: String)? {
        guard url.scheme == "smb", let host = url.host(percentEncoded: false) else { return nil }
        // pathComponents drops the leading "/" as its own "/" element: ["/", share, a, b].
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let share = segments.first else { return nil }
        let path = segments.dropFirst().joined(separator: "/")
        return (host, share, path)
    }
}

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
    /// - Parameters:
    ///   - host: bare host (no scheme/userinfo).
    ///   - share: share name.
    ///   - path: share-relative path with `/` separators; empty = the share root.
    /// - Returns: the encoded `smb://` URL, or nil if the components still can't form a URL.
    public static func make(host: String, share: String, path: String) -> URL? {
        // `.urlPathAllowed` keeps `/` (so path separators survive) and ordinary name
        // characters, while encoding `#`, `?`, spaces, brackets, etc.
        let pathChars = CharacterSet.urlPathAllowed
        let encHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        let encShare = share.addingPercentEncoding(withAllowedCharacters: pathChars) ?? share
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encPath = trimmedPath.addingPercentEncoding(withAllowedCharacters: pathChars) ?? trimmedPath
        let tail = encPath.isEmpty ? encShare : "\(encShare)/\(encPath)"
        return URL(string: "smb://\(encHost)/\(tail)")
    }

    /// Scheme-only connection URL (`smb://host`, no share/path, no userinfo) — what
    /// `SMB2Manager` derives its connection target from. Percent-encodes the host so a
    /// Bonjour-synthesised name with a space (e.g. "My NAS.local") forms a real URL and
    /// attempts a resolve, instead of silently collapsing to the bogus `smb://invalid`
    /// fallback. ONE home for that fallback subtlety — `AMSMB2Lister` and
    /// `SMBConnectionTarget` both build their connection URL here.
    public static func hostOnly(_ host: String) -> URL {
        let encHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        return URL(string: "smb://\(encHost)") ?? URL(string: "smb://invalid")!
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

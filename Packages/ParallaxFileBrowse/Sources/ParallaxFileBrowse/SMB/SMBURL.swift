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
}

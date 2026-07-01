import Foundation
import CoreMedia

/// Everything `PlayerViewModel.start(smbItem:)` needs to play a local SMB file —
/// built entirely by the caller (Task 11) from the file source + Keychain, with no
/// Jellyfin server in the loop. The VM stays decoupled from the SMB layer: it never
/// imports ParallaxFileBrowse's types, it just carries this pre-resolved value.
///
/// Sendable so it can cross the `start(smbItem:)` async boundary; it holds only
/// value types.
struct SMBPlaybackItem: Sendable {
    /// The `smb://host/share/path` URL libVLC opens directly (the validated primary
    /// path — credentials live in `vlcOptions`, NEVER in the URL string).
    let url: URL
    /// The title shown in the player chrome + Now Playing.
    let title: String
    /// Verbatim libVLC media options carrying the SMB credentials
    /// (`:smb-user=…`, `:smb-pwd=…`, `:smb-domain=…`), built by the caller from the
    /// Keychain. Passed straight to `PlayableAsset.vlcOptions`; never logged.
    let vlcOptions: [String]
    /// Resume offset, or nil. SMB/local has no server-side resume store yet, so the
    /// caller leaves this nil; the field exists so a local resume store can populate
    /// it later without changing the entry point.
    let startTime: CMTime?
    /// Pre-resolved sibling subtitle URLs (Task 7's filename-match resolver),
    /// keyed by a synthetic stream index. Mirrors the Jellyfin path's
    /// `subtitleStreamURLs` so `loadSidecarSubtitle` can find them.
    let subtitleURLs: [Int: URL]
    /// Total file size in bytes from the SMB directory listing. Lets the engine estimate a runtime
    /// for an incomplete/still-downloading file whose container length never resolves (no trailing
    /// moov atom). Nil when the size is unknown.
    let fileSizeBytes: Int64?

    init(
        url: URL,
        title: String,
        vlcOptions: [String],
        startTime: CMTime? = nil,
        subtitleURLs: [Int: URL] = [:],
        fileSizeBytes: Int64? = nil
    ) {
        self.url = url
        self.title = title
        self.vlcOptions = vlcOptions
        self.startTime = startTime
        self.subtitleURLs = subtitleURLs
        self.fileSizeBytes = fileSizeBytes
    }
}

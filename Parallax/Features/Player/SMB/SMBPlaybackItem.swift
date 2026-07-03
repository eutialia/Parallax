import Foundation
import CoreMedia
import ParallaxCore
import ParallaxPlayback

/// Everything `PlayerViewModel.start(smbItem:)` needs to play a local SMB file —
/// built entirely by the caller (Task 11) from the file source + Keychain, with no
/// Jellyfin server in the loop. The VM stays decoupled from the SMB layer: it never
/// imports ParallaxFileBrowse's types, it just carries this pre-resolved value.
///
/// Sendable so it can cross the `start(smbItem:)` async boundary; it holds only
/// value types.
struct SMBPlaybackItem: Sendable {
    /// The browsed item's identity (`SMBFileSource.itemID(share:path:)`-minted) — the
    /// key `SMBResumeStore` saves and reads local resume positions under. The VM
    /// stashes it for the session so progress beats can persist against it.
    let itemID: ItemID
    /// The `smb://host/share/path` URL libVLC opens directly (the validated primary
    /// path — credentials live in `vlcOptions`, NEVER in the URL string).
    let url: URL
    /// The title shown in the player chrome + Now Playing.
    let title: String
    /// Verbatim libVLC media options carrying the SMB credentials
    /// (`:smb-user=…`, `:smb-pwd=…`, `:smb-domain=…`), built by the caller from the
    /// Keychain. Passed straight to `PlayableAsset.vlcOptions`; never logged.
    let vlcOptions: [String]
    /// Resume offset, or nil for a fresh start. The resolver populates it from
    /// `SMBResumeStore` (the local resume store — no server holds SMB progress).
    let startTime: CMTime?
    /// Pre-resolved sibling subtitle URLs (Task 7's filename-match resolver),
    /// keyed by a synthetic stream index. Mirrors the Jellyfin path's
    /// `subtitleStreamURLs` so `loadSidecarSubtitle` can find them.
    let subtitleURLs: [Int: URL]
    /// Human-readable label per sidecar index (the resolver's `SMBSubtitleMatch.label`,
    /// e.g. `"en"`, `"en.forced"`, `"Default"`), so the subtitle menu can name each
    /// synthetic external track instead of showing a bare index. Keyed the same as
    /// `subtitleURLs`; a missing key falls back to a generated name.
    let subtitleLabels: [Int: String]
    /// Whether the VM's `currentDuration` will reflect a REAL container length rather than
    /// VLCKitEngine's fileSize×time/readBytes read-rate estimate (`VLCKitEngine.effectiveDurationMs`).
    /// `hasKnownDuration` is true for both — it only tests "is the duration numeric?" — so this bit
    /// is the only signal that distinguishes a synthesized guess from a proven length. `false` gates
    /// `SMBResumeStore`'s ≥95%-complete clear off: an estimate is low-biased against readBytes lagging
    /// the actual playhead, and clearing real progress against a guess would silently wipe a resume
    /// point. True on the bridge route (AVKit reads the container's own duration atom) and when the
    /// VLC route's probe proved the file complete; false on an unproven/incomplete VLC-route file.
    let hasTrustworthyDuration: Bool
    /// The routing hints the resolver's probe produced: `scheme "http"` (+ container/codecs) for a
    /// bridged AVKit file, or `scheme "smb"` for the VLC route. Drives `EngineSelector` in the VM.
    let hints: PlaybackHints
    /// Tears down the HTTP bridge + its SMB reader when the playback session ends. Non-nil ONLY on
    /// the bridge route; nil on the VLC route (libVLC owns its own smb:// connection). Opaque on
    /// purpose — it carries the `ParallaxFileBrowse` bridge/reader the VM must never import.
    let cleanup: (@Sendable () async -> Void)?

    init(
        itemID: ItemID,
        url: URL,
        title: String,
        vlcOptions: [String],
        startTime: CMTime? = nil,
        subtitleURLs: [Int: URL] = [:],
        subtitleLabels: [Int: String] = [:],
        // Defaults true: every existing call site (both production and test) predates the estimate
        // signal and means "a real duration" — only the resolver's VLC-route build passes false.
        hasTrustworthyDuration: Bool = true,
        hints: PlaybackHints = PlaybackHints(
            scheme: "smb", container: nil, videoCodec: nil, audioCodec: nil, subtitleFormats: []
        ),
        cleanup: (@Sendable () async -> Void)? = nil
    ) {
        self.itemID = itemID
        self.url = url
        self.title = title
        self.vlcOptions = vlcOptions
        self.startTime = startTime
        self.subtitleURLs = subtitleURLs
        self.subtitleLabels = subtitleLabels
        self.hasTrustworthyDuration = hasTrustworthyDuration
        self.hints = hints
        self.cleanup = cleanup
    }
}

import Foundation
import CoreMedia
import ParallaxCore

public struct PlayableAsset: Sendable {
    public let url: URL
    public let headers: [String: String]?         // nil for AVKit (auth via api_key query param)
    public let hints: PlaybackHints
    public let startTime: CMTime?
    /// Authoritative server-side track metadata used to label the engine's
    /// tracks (a transcode manifest often omits names/languages).
    public let mediaStreams: [MediaStreamInfo]
    /// Source stream index of the single transcoded audio/subtitle rendition,
    /// so the engine can name the one track the manifest carries.
    public let defaultAudioStreamIndex: Int?
    public let defaultSubtitleStreamIndex: Int?
    /// A font file for VLC's *simple* (SRT) text renderer (`:freetype-font=`). iOS has
    /// no font provider, so without this that renderer draws nothing. The app
    /// materializes a system font via CoreText. Nil = let the engine try its default
    /// (and on AVKit it is unused — AVFoundation renders subtitles itself).
    public let subtitleFontURL: URL?
    /// A directory of font files for VLC's libass (ASS/SSA) renderer (`:ssa-fontsdir=`).
    /// libass is a *separate* subsystem from the simple renderer and ignores
    /// `freetype-font`; on iOS it holds no fonts unless pointed at a directory to scan.
    /// The app materializes the CJK system faces here. Unused by AVKit.
    public let subtitleFontsDirectoryURL: URL?
    /// Verbatim libVLC media options (e.g. SMB credentials `:smb-user=…`,
    /// `:smb-pwd=…`), applied via `VLCMedia.addOption` after the engine's own.
    /// The package treats these as opaque — it does not know any are credentials.
    /// AVKit ignores them. **Never logged**: a value here can hold a password, so
    /// it must never be interpolated into a log or diagnostic string.
    public let vlcOptions: [String]?

    public init(
        url: URL,
        headers: [String: String]?,
        hints: PlaybackHints,
        startTime: CMTime?,
        mediaStreams: [MediaStreamInfo] = [],
        defaultAudioStreamIndex: Int? = nil,
        defaultSubtitleStreamIndex: Int? = nil,
        subtitleFontURL: URL? = nil,
        subtitleFontsDirectoryURL: URL? = nil,
        vlcOptions: [String]? = nil
    ) {
        self.url = url
        self.headers = headers
        self.hints = hints
        self.startTime = startTime
        self.mediaStreams = mediaStreams
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex
        self.subtitleFontURL = subtitleFontURL
        self.subtitleFontsDirectoryURL = subtitleFontsDirectoryURL
        self.vlcOptions = vlcOptions
    }
}

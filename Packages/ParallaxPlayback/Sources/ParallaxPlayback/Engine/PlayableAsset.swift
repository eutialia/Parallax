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
    /// A directory of font files for VLC's libass (ASS/SSA) renderer (`:ssa-fontsdir=`).
    /// libass is a *separate* subsystem from the simple freetype renderer and ignores
    /// `freetype-font`; on iOS it holds no fonts unless pointed at a directory to scan.
    /// The app materializes the CJK system faces here. Unused by AVKit.
    public let subtitleFontsDirectory: URL?
    /// The font FAMILY NAME for VLC's *simple* freetype renderer (SRT / plain `text`), passed
    /// as the `--freetype-font=` INSTANCE argument. libvlc 3.0's option is a family, not a
    /// path — a path is a silent no-op that falls back to the module's hardcoded Helvetica
    /// Neue. Must be a family the app registered with CoreText, and one that covers CJK
    /// ITSELF: the module's per-glyph fallback asks CoreText, which on iOS answers Han with
    /// a private-framework PingFang file FreeType cannot open. Nil = let the module use its
    /// default. Unused by AVKit (AVFoundation renders subtitles itself).
    public let subtitleFontFamily: String?
    /// The size and colours for that same freetype renderer — the user's `SubtitleStyle`,
    /// so an embedded SRT the ENGINE draws matches the cue the app's client renderer draws
    /// for an external one. Nil leaves the module on its own defaults.
    ///
    /// **Read once, when libvlc builds the PLAYER's library instance** — the freetype
    /// renderer belongs to the video output, not to a decoder, so this rides
    /// `vlcInstanceArguments` rather than a media option. A style change
    /// applies from the next item, not the playing one; client-rendered sidecar tracks have
    /// no such limit.
    public let subtitleTextStyle: EngineSubtitleTextStyle?
    /// The app draws EVERY text subtitle itself (client-side sidecar rendering), so the
    /// engine must never draw one: `VLCKitEngine` emits `:no-spu` and refuses any
    /// `setSubtitleTrack(_:)` selection for this asset. Without it libvlc auto-selects a
    /// default/forced embedded track as the demux discovers it and renders it THROUGH the
    /// overlay. Ignored by AVKit.
    public let engineSubtitlesDisabled: Bool
    /// Verbatim libVLC media options (e.g. SMB credentials `:smb-user=…`,
    /// `:smb-pwd=…`), applied via `VLCMedia.addOption` after the engine's own.
    /// The package treats these as opaque — it does not know any are credentials.
    /// AVKit ignores them. **Never logged**: a value here can hold a password, so
    /// it must never be interpolated into a log or diagnostic string.
    public let vlcOptions: [String]?
    /// Raw libvlc INSTANCE arguments (e.g. `--no-drop-late-frames`), for defects a
    /// per-media option can't reach — the vout's `is_late_dropped` flag inherits from
    /// the libvlc instance, not per-media variables, so `:no-drop-late-frames` on
    /// `vlcOptions` never takes effect. They join the subtitle look in
    /// `vlcInstanceArguments`, which is what the private libvlc instance
    /// backing the player is built from. Nil = nothing beyond the subtitle arguments.
    public let vlcLibraryOptions: [String]?

    /// A copy of `self` with `startTime` replaced and every other field carried over
    /// verbatim. The one mutated-copy site adjacent to the field list — callers that
    /// only need a different start time (the reactive AVKit→VLC fallback's retry asset)
    /// go through here instead of hand-rolling the full field list, which would
    /// silently drop any field added later.
    public func replacingStartTime(_ startTime: CMTime?) -> PlayableAsset {
        PlayableAsset(
            url: url,
            headers: headers,
            hints: hints,
            startTime: startTime,
            mediaStreams: mediaStreams,
            defaultAudioStreamIndex: defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
            subtitleFontsDirectory: subtitleFontsDirectory,
            subtitleFontFamily: subtitleFontFamily,
            subtitleTextStyle: subtitleTextStyle,
            engineSubtitlesDisabled: engineSubtitlesDisabled,
            vlcOptions: vlcOptions,
            vlcLibraryOptions: vlcLibraryOptions
        )
    }

    public init(
        url: URL,
        headers: [String: String]?,
        hints: PlaybackHints,
        startTime: CMTime?,
        mediaStreams: [MediaStreamInfo] = [],
        defaultAudioStreamIndex: Int? = nil,
        defaultSubtitleStreamIndex: Int? = nil,
        subtitleFontsDirectory: URL? = nil,
        subtitleFontFamily: String? = nil,
        subtitleTextStyle: EngineSubtitleTextStyle? = nil,
        engineSubtitlesDisabled: Bool = false,
        vlcOptions: [String]? = nil,
        vlcLibraryOptions: [String]? = nil
    ) {
        self.url = url
        self.headers = headers
        self.hints = hints
        self.startTime = startTime
        self.mediaStreams = mediaStreams
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex
        self.subtitleFontsDirectory = subtitleFontsDirectory
        self.subtitleFontFamily = subtitleFontFamily
        self.subtitleTextStyle = subtitleTextStyle
        self.engineSubtitlesDisabled = engineSubtitlesDisabled
        self.vlcOptions = vlcOptions
        self.vlcLibraryOptions = vlcLibraryOptions
    }
}

extension PlayableAsset {
    /// Every libvlc **instance** argument this asset needs, or nil when it needs none.
    ///
    /// Two families live here, for the same reason: neither is reachable from an input
    /// item's variables. `vlcLibraryOptions` carries the vout flags the app already knew
    /// about (`--no-drop-late-frames`); the `--freetype-*` set carries the subtitle look,
    /// because the freetype text renderer is owned by the video output rather than by a
    /// decoder (see `VLCKitEngine.mediaOptions(for:)`).
    ///
    /// Instance-scoped means these are fixed when the player is built, so the app compares
    /// this result against what the live engine was constructed with before it reuses one.
    /// The order is therefore load-bearing: same asset shape in, same array out.
    /// Pure, so the argument strings are testable without a live decode.
    public var vlcInstanceArguments: [String]? {
        var options = vlcLibraryOptions ?? []
        if let subtitleFontFamily {
            // A font FAMILY NAME ("Font family for the font you want to use" — libvlc 3.0's
            // freetype module), never a path: a path matches no family and drops the module
            // back onto its built-in default.
            options.append("--freetype-font=\(subtitleFontFamily)")
        }
        // The user's look AND the em the app's own renderer would have drawn at
        // (`EngineSubtitleTextStyle`), so an embedded SRT the ENGINE draws matches an
        // external one the CLIENT draws. ASS/SSA keep their authored styles either way
        // (libass ignores freetype-*).
        options.append(contentsOf: subtitleTextStyle?.freetypeSettings.map { "--\($0)" } ?? [])
        return options.isEmpty ? nil : options
    }
}

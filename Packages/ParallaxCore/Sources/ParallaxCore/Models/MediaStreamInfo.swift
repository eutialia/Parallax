import Foundation

/// Authoritative per-stream track metadata from the media server, carried
/// through to the player so track menus can show real names ("English ·
/// TrueHD 7.1") instead of whatever a transcode manifest happens to expose.
///
/// Neutral by design: lives in Core so ParallaxJellyfin can populate it and
/// ParallaxPlayback can consume it without either depending on the other.
public struct MediaStreamInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case video
        case audio
        case subtitle
        case other
    }

    /// The stream's index within its source media (Jellyfin's `MediaStream.index`).
    /// Stable identity and the key the server uses for `AudioStreamIndex` /
    /// `SubtitleStreamIndex` selection.
    public let index: Int
    public let kind: Kind
    /// The server's pre-formatted label, e.g. "English - TrueHD 7.1 - Default".
    /// Display fallback only — it bakes codec/layout into the name, which the
    /// menus now show on their own detail line (see `menuLabel`).
    public let displayTitle: String?
    /// The stream's own name from the container ("Director's Commentary"),
    /// without the server's codec/default decoration. Nil when the muxer set none.
    public let title: String?
    public let language: String?
    public let codec: String?
    public let channels: Int?
    /// A sidecar stream (external file), not muxed into the source container.
    public let isExternal: Bool
    public let isForced: Bool
    public let isDefault: Bool
    /// SDH (Subtitles for the Deaf and Hard-of-Hearing) subtitle track.
    public let isHearingImpaired: Bool

    // MARK: Debug / diagnostic fields (nil unless the server reported them)

    /// Codec profile, e.g. "Main 10", "High".
    public let profile: String?
    public let bitDepth: Int?
    public let width: Int?
    public let height: Int?
    /// "SDR" / "HDR" (Jellyfin `VideoRange`).
    public let videoRange: String?
    /// Granular HDR flavour: "HDR10" / "HLG" / "DOVI" / … (Jellyfin `VideoRangeType`).
    public let videoRangeType: String?
    public let colorSpace: String?
    /// Stream bitrate in bits per second.
    public let bitRate: Int?
    public let frameRate: Double?
    /// Audio sample rate in Hz.
    public let sampleRate: Int?
    /// How the server delivers a subtitle: "Embed" / "External" / "Hls" / "Encode" /
    /// "Drop". The key diagnostic for sync + render problems — "Hls" is segmented
    /// WebVTT (the AVFoundation desync path) and "Encode" is burned-in.
    public let subtitleDeliveryMethod: String?

    public var id: Int { index }

    public init(
        index: Int,
        kind: Kind,
        displayTitle: String?,
        title: String? = nil,
        language: String?,
        codec: String?,
        channels: Int?,
        isExternal: Bool,
        isForced: Bool,
        isDefault: Bool,
        isHearingImpaired: Bool = false,
        profile: String? = nil,
        bitDepth: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        videoRange: String? = nil,
        videoRangeType: String? = nil,
        colorSpace: String? = nil,
        bitRate: Int? = nil,
        frameRate: Double? = nil,
        sampleRate: Int? = nil,
        subtitleDeliveryMethod: String? = nil
    ) {
        self.index = index
        self.kind = kind
        self.displayTitle = displayTitle
        self.title = title
        self.language = language
        self.codec = codec
        self.channels = channels
        self.isExternal = isExternal
        self.isForced = isForced
        self.isDefault = isDefault
        self.isHearingImpaired = isHearingImpaired
        self.profile = profile
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
        self.videoRange = videoRange
        self.videoRangeType = videoRangeType
        self.colorSpace = colorSpace
        self.bitRate = bitRate
        self.frameRate = frameRate
        self.sampleRate = sampleRate
        self.subtitleDeliveryMethod = subtitleDeliveryMethod
    }
}

public extension MediaStreamInfo {
    /// A menu-ready PRIMARY name — just who the track is, never what it's made
    /// of (codec/layout live on the menus' detail line): the stream's own title
    /// ("Director's Commentary") → the localized language name ("English") →
    /// the server's display title as a last resort (it bakes in codec noise) →
    /// "Track N". Single source of truth, shared by the transcode menu and the
    /// AVKit track matcher.
    var menuLabel: String { menuLabel() }

    /// `menuLabel` with an injectable locale for the language-name tier (tests
    /// must not depend on the host locale).
    func menuLabel(locale: Locale = .current) -> String {
        preferredMenuName(locale: locale) ?? "Track \(index)"
    }

    /// The nil-falling core of `menuLabel`, for callers with their own final
    /// fallback (the AVKit matcher prefers its ordinal "Audio N" over "Track N").
    func preferredMenuName(locale: Locale = .current) -> String? {
        if let title = Self.nonEmpty(title) {
            return Self.strippingDefaultSuffix(title)
        }
        if let language = TrackDisplay.languageName(language, locale: locale) {
            return language
        }
        if let displayTitle = Self.nonEmpty(displayTitle) {
            return Self.strippingDefaultSuffix(displayTitle)
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Trims `title` and drops a trailing " - Default".
    static func strippingDefaultSuffix(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = " - Default"
        return trimmed.hasSuffix(suffix) ? String(trimmed.dropLast(suffix.count)) : trimmed
    }

    /// An image-based subtitle (PGS / VobSub / DVD / DVB) — the server can only
    /// deliver these by burning them into the video. Text formats (SubRip, ASS,
    /// WebVTT…) ride along in the HLS manifest and need no burn-in, so only they
    /// are offered on the transcode path until burn-in lands in a later phase.
    var isImageSubtitle: Bool {
        guard kind == .subtitle, let codec = codec?.lowercased() else { return false }
        let imageMarkers = ["pgs", "vobsub", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "xsub"]
        return imageMarkers.contains { codec.contains($0) }
    }
}

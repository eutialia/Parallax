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
    public let displayTitle: String?
    public let language: String?
    public let codec: String?
    public let channels: Int?
    /// A sidecar stream (external file), not muxed into the source container.
    public let isExternal: Bool
    public let isForced: Bool
    public let isDefault: Bool

    public var id: Int { index }

    public init(
        index: Int,
        kind: Kind,
        displayTitle: String?,
        language: String?,
        codec: String?,
        channels: Int?,
        isExternal: Bool,
        isForced: Bool,
        isDefault: Bool
    ) {
        self.index = index
        self.kind = kind
        self.displayTitle = displayTitle
        self.language = language
        self.codec = codec
        self.channels = channels
        self.isExternal = isExternal
        self.isForced = isForced
        self.isDefault = isDefault
    }
}

public extension MediaStreamInfo {
    /// A menu-ready label: the server's title (else language, else "Track N"),
    /// trimmed, with the redundant trailing " - Default" dropped (the menu marks
    /// the active track with a checkmark already). Single source of truth for the
    /// suffix rule, shared by the transcode menu and the AVKit track matcher.
    var menuLabel: String {
        Self.strippingDefaultSuffix(displayTitle ?? language ?? "Track \(index)")
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

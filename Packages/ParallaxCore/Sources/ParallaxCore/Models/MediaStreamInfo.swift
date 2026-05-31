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

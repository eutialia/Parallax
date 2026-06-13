import Foundation

/// A server-provided media segment — Jellyfin's native Media Segments API
/// (`GET /MediaSegments/{itemId}`, core server since 10.10). Positions are
/// absolute offsets from the start of the item. The segment table is empty
/// unless a provider plugin (e.g. Intro Skipper) has analyzed the item, so an
/// empty list is the normal "no data" case, never an error.
public struct MediaSegment: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: MediaSegmentKind
    public let start: Duration
    public let end: Duration

    public init(id: String, kind: MediaSegmentKind, start: Duration, end: Duration) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Absolute start/end in seconds — the bridge to `CMTime` and the player UI.
    public var startSeconds: Double { Self.seconds(start) }
    public var endSeconds: Double { Self.seconds(end) }

    /// Whether `seconds` falls inside `[startSeconds, endSeconds)` — half-open, so
    /// the exact end instant already counts as past the segment (the playhead
    /// leaving at the end clears the "active" state cleanly).
    public func contains(seconds: Double) -> Bool {
        seconds >= startSeconds && seconds < endSeconds
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// The content a `MediaSegment` marks. Mirrors the server's `MediaSegmentType`.
/// Parallax acts on `.intro`/`.recap` (Skip) and `.outro` (Next Episode); the
/// full set is modeled so an unhandled kind is explicit rather than silently
/// folded into one of the handled ones.
public enum MediaSegmentKind: Sendable, Hashable, CaseIterable {
    case intro
    case outro
    case recap
    case preview
    case commercial
    case unknown
}

/// What the player does when a segment is acted on. Skip and Next Episode are
/// the only two behaviors Parallax surfaces; everything else shows no button.
public enum MediaSegmentAction: Sendable, Hashable {
    /// Seek to the segment's end and keep playing (intro, recap).
    case skip
    /// Advance to the next episode (outro). The player only surfaces this when a
    /// next episode actually exists; otherwise the outro just plays out.
    case nextEpisode
}

public extension MediaSegmentKind {
    /// The player behavior for this kind, or nil when no button is shown.
    var playerAction: MediaSegmentAction? {
        switch self {
        case .intro, .recap: .skip
        case .outro: .nextEpisode
        case .preview, .commercial, .unknown: nil
        }
    }
}

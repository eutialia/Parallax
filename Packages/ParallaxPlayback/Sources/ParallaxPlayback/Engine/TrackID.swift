import Foundation

/// A track's identity, tagged with the namespace it belongs to.
///
/// Two subsystems hand out track ids that are both plain integers, and they are not
/// interchangeable:
/// - `avKitOption`: an index into an `AVMediaSelectionGroup.options` array.
/// - `jellyfinStream`: a source-media stream index the Jellyfin server uses for
///   `AudioStreamIndex` / `SubtitleStreamIndex` (the transcode re-resolve path).
///
/// As bare integers, option 2 and stream 2 selected the wrong track when one was passed for
/// the other. Each consumer pattern-matches the case it owns and ignores the rest.
public enum TrackID: Hashable, Sendable {
    case avKitOption(Int)
    case jellyfinStream(Int)
}

public extension TrackID {
    /// The Jellyfin source-stream index, if this id is in that namespace.
    var jellyfinStreamIndex: Int? {
        if case let .jellyfinStream(index) = self { return index }
        return nil
    }

    /// The AVKit media-selection option index, if this id is in that namespace.
    var avKitOptionIndex: Int? {
        if case let .avKitOption(index) = self { return index }
        return nil
    }
}

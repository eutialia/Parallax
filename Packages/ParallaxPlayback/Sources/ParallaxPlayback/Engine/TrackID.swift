import Foundation

/// A track's identity, tagged with the namespace it belongs to.
///
/// Two subsystems hand out track ids that are both plain integers, and they are not
/// interchangeable:
/// - `avKitOption`: an index into an `AVMediaSelectionGroup.options` array.
/// - `jellyfinStream`: a source-media stream index the Jellyfin server uses for
///   `AudioStreamIndex` / `SubtitleStreamIndex` (the transcode re-resolve path).
/// - `fileStream`: a stream's place in the played file, for a subtitle the app draws from the
///   lines the bridge reads out of that file.
///
/// As bare integers, option 2 and stream 2 selected the wrong track when one was passed for
/// the other. Each consumer pattern-matches the case it owns and ignores the rest.
public enum TrackID: Hashable, Sendable {
    case avKitOption(Int)
    case jellyfinStream(Int)
    case fileStream(Int)
}

public extension TrackID {
    /// The Jellyfin source-stream index, if this id is in that namespace.
    var jellyfinStreamIndex: Int? {
        if case let .jellyfinStream(index) = self { return index }
        return nil
    }

    /// The stream's place in the played file, if this id is in that namespace.
    var fileStreamIndex: Int? {
        if case let .fileStream(index) = self { return index }
        return nil
    }

    /// The AVKit media-selection option index, if this id is in that namespace.
    var avKitOptionIndex: Int? {
        if case let .avKitOption(index) = self { return index }
        return nil
    }
}

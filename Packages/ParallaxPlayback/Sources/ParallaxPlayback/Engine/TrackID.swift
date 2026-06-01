import Foundation

/// A track's identity, tagged with the namespace it belongs to.
///
/// Three different subsystems hand out track ids that are all "just integers or
/// strings", and they are NOT interchangeable:
/// - `avKitOption` — an index into an `AVMediaSelectionGroup.options` array.
/// - `vlc` — a `VLCMediaPlayer.Track.trackId` string.
/// - `jellyfinStream` — a source-media stream index the Jellyfin server uses for
///   `AudioStreamIndex` / `SubtitleStreamIndex` (the transcode re-resolve path).
///
/// Before this type they were all `String`, so an AVKit option index ("2") and a
/// Jellyfin stream index ("2") were indistinguishable — feeding one where the
/// other was expected silently selected the wrong track. Encoding the namespace
/// makes that a compile-time impossibility: each consumer pattern-matches the
/// case it owns and ignores the rest.
public enum TrackID: Hashable, Sendable {
    case avKitOption(Int)
    case vlc(String)
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

    /// The VLC `trackId`, if this id is in that namespace.
    var vlcTrackID: String? {
        if case let .vlc(value) = self { return value }
        return nil
    }
}

import Foundation

/// Where a tile's artwork comes from, independent of media source.
///
/// Jellyfin renders through its per-session Nuke pipeline (which carries auth),
/// not through this type — so the Jellyfin path keeps its Session+pipeline.
/// SMB produces `.local` thumbnails generated from the video.
public enum ArtworkSource: Sendable, Hashable {
    case local(URL)
    case none
}

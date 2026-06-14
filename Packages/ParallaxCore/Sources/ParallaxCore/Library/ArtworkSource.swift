import Foundation

/// Where a tile's artwork comes from, independent of media source.
///
/// Jellyfin renders through its per-session Nuke pipeline (which carries auth),
/// not through this type — so the Jellyfin path keeps its Session+pipeline.
/// Phase-2 SMB produces `.local` thumbnails generated from the video; `.remote`
/// is reserved for a future headered remote source.
public enum ArtworkSource: Sendable, Hashable {
    case remote(URL, headers: [String: String]?)
    case local(URL)
    case none
}

import Foundation
import JellyfinAPI

extension BaseItemDto {
    /// Whether the item has embedded or sidecar subtitle tracks.
    var hasSubtitleTracks: Bool {
        if hasSubtitles == true { return true }
        return mediaStreams?.contains(where: { $0.type == .subtitle }) ?? false
    }
}

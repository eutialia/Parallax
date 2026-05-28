import Foundation
import CoreMedia

public enum PlaybackState: Sendable {
    case idle
    case loading
    case ready(duration: CMTime, tracks: TrackInventory)
    case playing(position: CMTime, duration: CMTime)
    case paused(position: CMTime, duration: CMTime)
    case ended
    case failed(PlaybackError)
}

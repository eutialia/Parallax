import Foundation

public enum PlaybackError: Error, Sendable, Equatable {
    case assetNotPlayable        // AVPlayerItem never became .readyToPlay
    case decodeFailed            // AVPlayerItem.status == .failed mid-playback
    case networkStalled          // playback buffer emptied and did not recover
    case unknown(String)

    public static func == (lhs: PlaybackError, rhs: PlaybackError) -> Bool {
        switch (lhs, rhs) {
        case (.assetNotPlayable, .assetNotPlayable): return true
        case (.decodeFailed, .decodeFailed): return true
        case (.networkStalled, .networkStalled): return true
        case (.unknown(let l), .unknown(let r)): return l == r
        default: return false
        }
    }
}

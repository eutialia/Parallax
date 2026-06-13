import Foundation

/// Identifies which concrete engine backs a playback session. The selector picks one per
/// asset based on container/codec support.
public enum PlaybackEngineID: String, Sendable, Hashable {
    /// AVFoundation/AVKit — direct play and HLS.
    case avKit
    /// VLCKit — the fallback decoder for containers/codecs AVFoundation can't play.
    case vlcKit
}

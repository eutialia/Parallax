import Foundation

/// A failure surfaced by a `PlaybackEngine` on its state stream. The app maps these to a
/// user-facing `AppError.playback`; engines stay URL- and provider-agnostic, so the cases
/// describe playback states, never network/auth specifics.
public enum PlaybackError: Error, Sendable, Equatable {
    /// The asset never became playable (`AVPlayerItem` never reached `.readyToPlay`).
    case assetNotPlayable
    /// The playback buffer emptied and did not recover.
    case networkStalled
    /// The item produced neither a first frame nor an error inside the engine's load
    /// deadline (`LoadWatchdog`). Deliberately NOT `assetNotPlayable`, which it used to
    /// borrow: nothing about the asset is known to be wrong — a cold transcode, a slow
    /// server or a wedged segment fetch all land here, and reporting them as a decode
    /// failure points the user at the file instead of the link.
    case loadTimedOut
    /// An engine-specific failure outside the cases above; the string is a log-safe
    /// summary, not user-facing copy.
    case unknown(String)
}

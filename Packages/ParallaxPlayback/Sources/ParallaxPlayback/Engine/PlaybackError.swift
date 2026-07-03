import Foundation

/// A failure surfaced by a `PlaybackEngine` on its state stream. The app maps these to a
/// user-facing `AppError.playback`; engines stay URL- and provider-agnostic, so the cases
/// describe playback states, never network/auth specifics.
public enum PlaybackError: Error, Sendable, Equatable {
    /// The asset never became playable (`AVPlayerItem` never reached `.readyToPlay`).
    case assetNotPlayable
    /// The playback buffer emptied and did not recover.
    case networkStalled
    /// An engine-specific failure outside the cases above; the string is a log-safe
    /// summary, not user-facing copy.
    case unknown(String)

    public static func == (lhs: PlaybackError, rhs: PlaybackError) -> Bool {
        switch (lhs, rhs) {
        case (.assetNotPlayable, .assetNotPlayable): return true
        case (.networkStalled, .networkStalled): return true
        case (.unknown(let l), .unknown(let r)): return l == r
        default: return false
        }
    }
}

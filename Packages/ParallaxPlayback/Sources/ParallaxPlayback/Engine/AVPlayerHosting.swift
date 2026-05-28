import AVFoundation

/// Adopted by `AVKitEngine` so the app target can set `AVPlayerViewController.player`
/// without `PlaybackEngine` leaking AVKit-UI types. The app casts `any PlaybackEngine`
/// to `any AVPlayerHosting` at the `PlayerView` boundary.
public protocol AVPlayerHosting: AnyObject {
    /// The underlying `AVPlayer` instance. Accessed `nonisolated` so the app target
    /// can read it from a `UIViewControllerRepresentable` make/update context.
    nonisolated var avPlayer: AVPlayer { get }
}

import MobileVLCKit

/// Adopted by `VLCKitEngine` so the app target can access the underlying
/// `VLCMediaPlayer` for `drawable` wiring without `PlaybackEngine` leaking VLC types.
/// Mirrors the `AVPlayerHosting` pattern for `AVKitEngine`.
///
/// The app target casts `any PlaybackEngine` to `any VLCPlayerHosting` at the
/// `VLCVideoHost` UIViewRepresentable boundary to set `vlcPlayer.drawable = view`.
///
/// This protocol's signature names `VLCMediaPlayer`, so the app target imports
/// `MobileVLCKit` alongside `ParallaxPlayback` to name it. The binary target propagates
/// out of the package, so no product declaration or re-export shim is needed.
public protocol VLCPlayerHosting: AnyObject {
    /// The underlying `VLCMediaPlayer`. Accessed `nonisolated` so
    /// `UIViewRepresentable` make/update contexts (off-main or synchronous)
    /// can read it without a `MainActor` hop.
    nonisolated var vlcPlayer: VLCMediaPlayer { get }
}

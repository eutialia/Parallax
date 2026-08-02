#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif

/// Adopted by `VLCKitEngine` so the app target can access the underlying
/// `VLCMediaPlayer` for `drawable` wiring without `PlaybackEngine` leaking VLC types.
/// Mirrors the `AVPlayerHosting` pattern for `AVKitEngine`.
///
/// The app target casts `any PlaybackEngine` to `any VLCPlayerHosting` at the
/// `VLCVideoHost` UIViewRepresentable boundary to set `vlcPlayer.drawable = view`.
///
/// This protocol's signature names `VLCMediaPlayer`, so the app target imports VLCKit
/// alongside `ParallaxPlayback` to name it — through the same `canImport` module pick
/// used here, since the module is `MobileVLCKit` on iOS and `TVVLCKit` on tvOS. The
/// binary target propagates out of the package, so no product declaration or re-export
/// shim is needed.
public protocol VLCPlayerHosting: AnyObject {
    /// The underlying `VLCMediaPlayer`. Accessed `nonisolated` so
    /// `UIViewRepresentable` make/update contexts (off-main or synchronous)
    /// can read it without a `MainActor` hop.
    nonisolated var vlcPlayer: VLCMediaPlayer { get }
}

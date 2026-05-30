import VLCKitSPM

/// Adopted by `VLCKitEngine` so the app target can access the underlying
/// `VLCMediaPlayer` for `drawable` and PiP wiring without `PlaybackEngine`
/// leaking VLC types. Mirrors the `AVPlayerHosting` pattern for `AVKitEngine`.
///
/// The app target casts `any PlaybackEngine` to `any VLCPlayerHosting` at the
/// `VLCVideoHost` UIViewRepresentable boundary to set
/// `vlcPlayer.drawable = coordinator` and call `addPlaybackSlave(...)`.
public protocol VLCPlayerHosting: AnyObject {
    /// The underlying `VLCMediaPlayer`. Accessed `nonisolated` so
    /// `UIViewRepresentable` make/update contexts (off-main or synchronous)
    /// can read it without a `MainActor` hop.
    nonisolated var vlcPlayer: VLCMediaPlayer { get }
}

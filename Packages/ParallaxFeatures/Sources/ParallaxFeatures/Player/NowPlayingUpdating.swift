import CoreMedia

/// The lock-screen seam the view model owns. `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter` are process-wide system singletons, so tests inject a
/// recording double here instead of asserting through the live info center — which
/// answers whatever the last test (or the system) left in it.
@MainActor
public protocol NowPlayingUpdating: AnyObject {
    func configure(
        onSeek: @escaping @MainActor (CMTime) -> Void,
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void,
        onToggle: @escaping @MainActor () -> Void
    )
    func update(position: CMTime, duration: CMTime, isPlaying: Bool, title: String)
    func clear()
}

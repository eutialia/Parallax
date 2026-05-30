import MediaPlayer
import CoreMedia

/// Drives `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for both engines.
/// Engine-agnostic: the VM calls `update(...)` on every `PlaybackState` event;
/// remote-command callbacks forward to the VM via the closures set in `configure(...)`.
@MainActor
final class NowPlayingController {
    private var seekHandler: ((CMTime) -> Void)?
    private var playHandler: (() -> Void)?
    private var pauseHandler: (() -> Void)?

    /// (command, target token) pairs — kept so we can `removeTarget` on teardown.
    /// Simply dropping the token does NOT deregister; the shared command center
    /// retains its own reference, so we must call removeTarget explicitly.
    private var registrations: [(MPRemoteCommand, Any)] = []

    init() {}

    isolated deinit {
        removeAllTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Registers remote-command handlers that forward to the VM. Call once per
    /// player setup. Idempotent: removes any prior registrations first.
    func configure(
        onSeek: @escaping @MainActor (CMTime) -> Void,
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void
    ) {
        removeAllTargets()   // guard against double-configure accumulating handlers
        seekHandler = onSeek
        playHandler = onPlay
        pauseHandler = onPause

        let center = MPRemoteCommandCenter.shared()

        let playToken = center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.playHandler?()
            return .success
        }
        let pauseToken = center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pauseHandler?()
            return .success
        }
        let toggleToken = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
            if rate > 0 { self.pauseHandler?() } else { self.playHandler?() }
            return .success
        }
        let seekToken = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.seekHandler?(CMTime(seconds: e.positionTime, preferredTimescale: 600))
            return .success
        }

        registrations = [
            (center.playCommand, playToken),
            (center.pauseCommand, pauseToken),
            (center.togglePlayPauseCommand, toggleToken),
            (center.changePlaybackPositionCommand, seekToken),
        ]
    }

    /// Write the full Now Playing info dict. Call on every state change and seek.
    func update(position: CMTime, duration: CMTime, isPlaying: Bool, title: String) {
        let elapsed = CMTimeGetSeconds(position)
        let total = CMTimeGetSeconds(duration)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: total.isNaN ? 0.0 : total,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isNaN ? 0.0 : elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    /// Clear Now Playing info and deregister remote commands (call on teardown).
    func clear() {
        removeAllTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func removeAllTargets() {
        for (command, token) in registrations {
            command.removeTarget(token)
        }
        registrations.removeAll()
    }
}

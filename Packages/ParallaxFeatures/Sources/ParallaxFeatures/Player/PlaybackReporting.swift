import Foundation
import ParallaxJellyfin

/// App-side seam over the three Jellyfin progress-report calls. PlayerViewModel
/// depends on this protocol (not the concrete PlaybackInfoService actor) so the
/// integration test can inject a recording stub. Every requirement matches the
/// actor's signature exactly.
public nonisolated protocol PlaybackReporting: Sendable {
    func reportStart(_ beat: ProgressBeat) async
    func reportProgress(_ beat: ProgressBeat) async
    func reportStopped(_ beat: ProgressBeat) async
    /// Kills the session's server-side transcode job (`DELETE
    /// /Videos/ActiveEncodings`). Fired before resolving a replacement stream
    /// (track switch) and on player exit. `reportStopped` kills the same job, but only
    /// for a session that reported start; this also covers one that never did.
    func stopEncoding(playSessionID: String) async
    /// Resets the server's 60s idle kill timer for the session's transcode job
    /// (`POST /Sessions/Playing/Ping`). The VM fires this on a timer while a
    /// transcode session is mounted — segment requests stop when the buffer
    /// fills during a pause, and the idle kill would delete the job + segments.
    func pingSession(playSessionID: String) async
}

extension PlaybackInfoService: PlaybackReporting {}

/// Inert `PlaybackReporting` for source-agnostic sessions with no Jellyfin server
/// to report to (the SMB/local path). The VM's real safety is the `resolved == nil`
/// gate in its beat handler — an SMB session never builds a beat to send — so this
/// is belt-and-suspenders: it lets the player be constructed for a local file
/// without wiring a live `PlaybackInfoService`.
struct NoOpPlaybackReporting: PlaybackReporting {
    func reportStart(_ beat: ProgressBeat) async {}
    func reportProgress(_ beat: ProgressBeat) async {}
    func reportStopped(_ beat: ProgressBeat) async {}
    func stopEncoding(playSessionID: String) async {}
    func pingSession(playSessionID: String) async {}
}

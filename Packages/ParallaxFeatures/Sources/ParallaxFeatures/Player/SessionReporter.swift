import CoreMedia
import Foundation
import ParallaxJellyfin

/// The Jellyfin play session's side of playback: the start, progress and stop reports, the kill
/// of its transcode job, and the keepalive that holds that job open. Each report and the kill
/// happen once per session; a reload opens a new session with `beginSession()`.
@MainActor
final class SessionReporter {
    private let playbackInfo: any PlaybackReporting
    /// The keepalive's waits.
    private let clock: any Clock<Duration>
    /// Ping cadence for `keepaliveTask` — half the server's 60s idle kill
    /// timeout in production; injectable so tests don't wait 30s for a beat.
    private let keepaliveInterval: Duration
    /// Keepalive for the server's transcode job: pings the play session on a
    /// timer so the 60s idle kill never fires while the player is mounted.
    /// Segment requests stop once a PAUSED player's buffer fills, and progress
    /// beats stop with them (the periodic observer is quiet at rate 0) — so a
    /// pause >60s would otherwise get the job AND its segments deleted, and
    /// resume would pay a cold ffmpeg respawn (the endless-buffering wedge).
    /// Runs while playing too: redundant next to segment traffic, but immune
    /// to the player's fetch cadence. Transcode sessions only.
    private var keepaliveTask: Task<Void, Never>?
    private var didReportStart = false
    private var didReportStopped = false
    /// Whether this session's server-side encoding was already killed. NOT
    /// gated on `didReportStart` like the stop report — the transcode job
    /// exists from resolve time, so a session that wedged before its first
    /// `.playing` beat still has a job to kill on exit.
    private var didStopEncoding = false

    init(playbackInfo: any PlaybackReporting, clock: any Clock<Duration>, keepaliveInterval: Duration) {
        self.playbackInfo = playbackInfo
        self.clock = clock
        self.keepaliveInterval = keepaliveInterval
    }

    isolated deinit {
        keepaliveTask?.cancel()
    }

    /// The reporting half of a live beat. `opensSession` — whether this beat may be the one
    /// that reports PlaybackStart: every `.playing` beat may, and so may a re-anchor's first
    /// live beat, which is a paused one whenever the user scrubbed while paused. Jellyfin
    /// expects a start before any progress, so a `.paused` beat that is neither (a remote/PiP
    /// pause landing during a cold start's buffering) still reports nothing.
    ///
    /// Returns whether this beat opened the session.
    func reportLiveBeat(
        position: CMTime, isPaused: Bool, opensSession: Bool, for resolved: ResolvedPlayback
    ) async -> Bool {
        if didReportStart {
            await playbackInfo.reportProgress(beat(position: position, isPaused: isPaused, from: resolved))
            return false
        }
        guard opensSession else { return false }
        didReportStart = true
        await playbackInfo.reportStart(beat(position: position, isPaused: isPaused, from: resolved))
        return true
    }

    /// Sends the final PlaybackStopped beat for the current session exactly once.
    /// Shared by `stop()`, a natural `.ended`, and a transcode track switch (which
    /// closes the outgoing session before opening the next).
    ///
    /// Requires `didReportStart`: a session that never reported start must never
    /// report stop. Without this guard a re-resolve that *fails* (so the flags were
    /// reset but the player's `resolved` was never advanced past the old/failed session)
    /// would let `stop()` fire a second/orphan PlaybackStopped.
    func reportStoppedIfNeeded(at lastPosition: CMTime, for resolved: ResolvedPlayback?) async {
        guard let resolved, didReportStart, !didReportStopped else { return }
        didReportStopped = true
        await playbackInfo.reportStopped(beat(position: lastPosition, isPaused: true, from: resolved))
    }

    /// (Re)arms the transcode keepalive for the just-resolved session: pings
    /// the play session every `keepaliveInterval` so the server's 60s idle
    /// kill never reaps the job while the player is mounted (a paused player
    /// stops requesting segments once buffered, and progress beats stop with
    /// it). Direct play has no job — the previous task is cancelled and none
    /// is armed.
    func startKeepalive(for resolved: ResolvedPlayback) {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        guard resolved.method == .transcode else { return }
        let sessionID = resolved.playSessionID
        let interval = keepaliveInterval
        keepaliveTask = Task { [playbackInfo, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                await playbackInfo.pingSession(playSessionID: sessionID)
            }
        }
    }

    /// Kills the outgoing session's server-side transcode job, exactly once.
    /// MUST run before resolving a replacement stream: with throttling off, an
    /// abandoned 4K job keeps transcoding flat-out and starves the new job's
    /// segment production past AVPlayer's 3s timeout — every post-switch
    /// segment then dies with -12889 in an unrecoverable buffering livelock
    /// (device-diagnosed 2026-06-11). jellyfin-web fires the same call before
    /// every in-place stream change. Direct play has no job — skip.
    func stopEncodingIfNeeded(for resolved: ResolvedPlayback?) async {
        guard let resolved, resolved.method == .transcode, !didStopEncoding else { return }
        didStopEncoding = true
        await playbackInfo.stopEncoding(playSessionID: resolved.playSessionID)
    }

    /// No keepalive: the session's job is gone, or there is no engine left to consume it.
    func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// A fresh play session that must report start, stop and kill its encoding on its own terms.
    func beginSession() {
        didReportStart = false
        didReportStopped = false
        didStopEncoding = false
    }

    private func beat(
        position: CMTime,
        isPaused: Bool,
        from resolved: ResolvedPlayback
    ) -> ProgressBeat {
        ProgressBeat(
            positionTicks: PlaybackInfoService.ticks(from: position),
            isPaused: isPaused,
            method: resolved.method,
            itemID: resolved.itemID,
            mediaSourceID: resolved.mediaSourceID,
            playSessionID: resolved.playSessionID
        )
    }
}

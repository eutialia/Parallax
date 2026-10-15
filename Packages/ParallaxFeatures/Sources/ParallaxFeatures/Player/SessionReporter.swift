import CoreMedia
import Foundation
import ParallaxJellyfin

/// The Jellyfin play session's side of playback: the start, progress and stop reports, the kill
/// of its transcode job, and the keepalive that holds that job open. Every latch lives on the
/// session it belongs to, so `begin(session:)` is the only reset: a re-resolve that never lands
/// leaves the old session's latches standing, and nothing can kill its encode a second time.
@MainActor
final class SessionReporter {
    private let playbackInfo: any PlaybackReporting
    /// The keepalive's waits.
    private let clock: any Clock<Duration>
    /// Ping cadence for `keepaliveTask`: half the server's 60s idle kill timeout.
    static let keepaliveInterval: Duration = .seconds(30)
    /// Keepalive for the server's transcode job: pings the play session on a
    /// timer so the 60s idle kill never fires while the player is mounted.
    /// Segment requests stop once a PAUSED player's buffer fills, and progress
    /// beats stop with them (the periodic observer is quiet at rate 0) — so a
    /// pause >60s would otherwise get the job AND its segments deleted, and
    /// resume would pay a cold ffmpeg respawn (the endless-buffering wedge).
    /// Runs while playing too: redundant next to segment traffic, but immune
    /// to the player's fetch cadence. Transcode sessions only.
    private var keepaliveTask: Task<Void, Never>?

    /// One play session as the server knows it, and what has been said about it.
    private struct PlaySession {
        let resolved: ResolvedPlayback
        /// PlaybackStart went out and no PlaybackStopped has closed it since. A stopped session
        /// reopens on its next opening beat: the fallback after a failed re-resolve resumes the
        /// outgoing stream, and the server simply sees that session play again.
        var isOpen = false
        /// NOT gated on `isOpen` like the stop report: the transcode job exists from resolve
        /// time, so a session that wedged before its first `.playing` beat still has a job to
        /// kill on exit.
        var didStopEncoding = false
    }
    private var session: PlaySession?

    init(playbackInfo: any PlaybackReporting, clock: any Clock<Duration>) {
        self.playbackInfo = playbackInfo
        self.clock = clock
    }

    isolated deinit {
        keepaliveTask?.cancel()
    }

    /// A fresh play session that reports start, stop and kills its encoding on its own terms.
    /// Arms the transcode keepalive: a paused player stops requesting segments once buffered,
    /// and progress beats stop with it, so without the pings the server's 60s idle kill reaps
    /// the job. Direct play has no job — the previous task is cancelled and none is armed.
    func begin(session resolved: ResolvedPlayback) {
        session = PlaySession(resolved: resolved)
        keepaliveTask?.cancel()
        keepaliveTask = nil
        guard resolved.method == .transcode else { return }
        let sessionID = resolved.playSessionID
        let interval = Self.keepaliveInterval
        keepaliveTask = Task { [playbackInfo, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                await playbackInfo.pingSession(playSessionID: sessionID)
            }
        }
    }

    /// The reporting half of a live beat. `opensSession` — whether this beat may be the one
    /// that reports PlaybackStart: every `.playing` beat may, and so may a reload's first
    /// live beat, which is a paused one whenever the reload landed paused. Jellyfin
    /// expects a start before any progress, so a `.paused` beat that is neither (a remote/PiP
    /// pause landing during a cold start's buffering) still reports nothing.
    ///
    /// Returns whether this beat opened the session.
    func reportLiveBeat(position: CMTime, isPaused: Bool, opensSession: Bool) async -> Bool {
        guard let current = session else { return false }
        if current.isOpen {
            await playbackInfo.reportProgress(beat(position: position, isPaused: isPaused, from: current.resolved))
            return false
        }
        guard opensSession else { return false }
        session?.isOpen = true
        await playbackInfo.reportStart(beat(position: position, isPaused: isPaused, from: current.resolved))
        return true
    }

    /// Sends the final PlaybackStopped beat for an open session. Shared by `stop()`, a natural
    /// `.ended`, and a reload (which closes the outgoing session before opening the next). A
    /// session that never reported start never reports stop.
    func reportStoppedIfNeeded(at lastPosition: CMTime) async {
        guard let current = session, current.isOpen else { return }
        session?.isOpen = false
        let final = beat(position: lastPosition, isPaused: true, from: current.resolved)
        await Self.outlivingTeardown { [playbackInfo] in await playbackInfo.reportStopped(final) }
    }

    /// Kills the session's server-side transcode job, exactly once, and with it the keepalive
    /// that would otherwise ping a dead play session.
    /// MUST run before resolving a replacement stream: with throttling off, an
    /// abandoned 4K job keeps transcoding flat-out and starves the new job's
    /// segment production past AVPlayer's 3s timeout — every post-switch
    /// segment then dies with -12889 in an unrecoverable buffering livelock
    /// (device-diagnosed 2026-06-11). jellyfin-web fires the same call before
    /// every in-place stream change. Direct play has no job — skip.
    func stopEncodingIfNeeded() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        guard let current = session, current.resolved.method == .transcode, !current.didStopEncoding else { return }
        session?.didStopEncoding = true
        let playSessionID = current.resolved.playSessionID
        await Self.outlivingTeardown { [playbackInfo] in await playbackInfo.stopEncoding(playSessionID: playSessionID) }
    }

    /// The final requests of a session are sent from the paths that tear it down, and a
    /// cancelled request never reaches the server. Each latch above is already spent, so a
    /// lost request is never retried: run it outside the caller's cancellation.
    private static func outlivingTeardown(_ request: @escaping @Sendable () async -> Void) async {
        await Task { await request() }.value
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

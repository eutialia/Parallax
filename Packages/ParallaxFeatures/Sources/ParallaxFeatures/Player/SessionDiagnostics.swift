import Foundation
import Observation
import ParallaxJellyfin

/// What the debug overlay reads about the live session: how long it took to start, and what the
/// transcode job is doing to the video.
@Observable
@MainActor
final class SessionDiagnostics {
    /// Milliseconds on the player's clock from `engine.play()` dispatch to this session's FIRST
    /// `.playing` beat — the debug overlay's `Startup:` row (Plan C, AVKit startup
    /// tuning A/B). `nil` before the first beat lands and reset per session/reload
    /// (see `startupClockStart`). Engine-agnostic: set for VLCKit sessions too, though
    /// only AVKit is presently tunable.
    private(set) var startupMillis: Int?
    /// Set at `engine.play()` dispatch (`PlayerViewModel.loadAndPlay`), consumed (cleared) by the
    /// first `.playing` beat this session — see `startupMillis`. `nil` after
    /// consumption so a later `.playing` beat (pause/resume, mid-stream rebuffer)
    /// never overwrites the metric.
    @ObservationIgnored private var startupClockStart: Duration?

    /// What the live transcode job is ACTUALLY doing to the video (copy/remux vs
    /// re-encode) — the copy-vs-reencode signal `PlaybackInfo` can't give (the server
    /// reports `Transcode` for stream-copy jobs too; only the running session's
    /// `TranscodingInfo` distinguishes them, once ffmpeg has started). Nil until the
    /// probe lands (and on direct-play / SMB, which never probe; and in Release,
    /// where the probe never arms). DEBUG-display only — it feeds the delivery debug
    /// row. The seek gate deliberately IGNORES it: every out-of-buffer transcode
    /// seek re-anchors regardless of delivery (see `PlayerViewModel.seek(to:)`); re-adding an
    /// `isVideoDirect` exemption reintroduces the 2026-07-17 video-copy desync.
    /// Cleared with the session; re-fetched after a track-switch rebuild, since a
    /// burn-in subtitle flips `isVideoDirect` false.
    private(set) var transcodeDelivery: TranscodeDelivery?
    /// True once the delivery probe's schedule ran out with no result — the debug row
    /// can say so instead of reading "probing…" forever. Reset on each new probe.
    private(set) var deliveryProbeExhausted = false
    /// The one-shot delivery probe for the current session — stored so session
    /// teardown cancels it (like `keepaliveTask`). Re-armed on each session's first
    /// `.playing` beat, which includes a track-switch rebuild.
    @ObservationIgnored private var deliveryProbeTask: Task<Void, Never>?

    /// The delivery probe's waits.
    @ObservationIgnored private let clock: any Clock<Duration>
    /// `clock` as time elapsed, for the startup metric.
    @ObservationIgnored private let elapsed: @Sendable () -> Duration
    /// Probes the live transcode's copy-vs-reencode delivery (`TranscodeDelivery`)
    /// by play-session id. Defaulted to a nil-returning no-op so SMB, previews, and
    /// tests that don't care need no wiring; the Jellyfin path injects
    /// `PlaybackInfoService.transcodingDelivery`. Nil = ffmpeg hasn't started, no
    /// matching session yet, or the probe failed — the probe treats it as "ask again".
    @ObservationIgnored private let fetchDelivery: @Sendable (String) async -> TranscodeDelivery?
    /// Wait-then-fetch schedule for the delivery probe: one sleep+fetch per entry, in
    /// order, until a non-nil result lands or the schedule runs out. It waits ~2s after
    /// the first `.playing` beat (ffmpeg starts lazily, `TranscodingInfo` isn't populated
    /// instantly), then retries once at +5s before giving up silently.
    static let deliveryProbeSchedule: [Duration] = [.seconds(2), .seconds(5)]

    init(
        clock: any Clock<Duration>,
        fetchDelivery: @escaping @Sendable (String) async -> TranscodeDelivery?
    ) {
        self.clock = clock
        self.elapsed = clock.stopwatch()
        self.fetchDelivery = fetchDelivery
    }

    isolated deinit {
        deliveryProbeTask?.cancel()
    }

    /// `engine.play()` was dispatched: start the clock the first `.playing` beat stops.
    func armStartupClock() {
        startupClockStart = elapsed()
    }

    /// A `.playing` beat landed. Only the session's first lands the metric; it consumes the
    /// anchor, so a later `.playing` (resume-from-pause, post-stall) never overwrites it.
    func notePlaying() {
        guard let clockStart = startupClockStart else { return }
        startupClockStart = nil
        startupMillis = Self.millis(elapsed() - clockStart)
    }

    /// The session restarts: no metric until its own first beat.
    func resetStartup() {
        startupClockStart = nil
        startupMillis = nil
    }

    /// The session's transcode job is gone: so is the verdict on it, and any probe still asking.
    func dropDelivery() {
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil
    }

    /// A reload opens a fresh session: the outgoing one's metric and delivery verdict must not
    /// linger, and a stale "exhausted" must not either — the debug row gates on it while
    /// `transcodeDelivery` is nil, and would read "no delivery info" for the whole reload
    /// window instead of "probing…" until the new session's first `.playing` beat re-probes.
    func resetForReload() {
        resetStartup()
        dropDelivery()
        deliveryProbeExhausted = false
    }

    /// Arms the one-shot copy-vs-reencode delivery probe for the just-started
    /// transcode session. ffmpeg spins up lazily and only populates the session's
    /// `TranscodingInfo` once it's encoding, so the probe walks `deliveryProbeSchedule`
    /// (≈2s then +5s in production) waiting then fetching at each step; a nil result
    /// (session/`TranscodingInfo` not up yet) moves to the next entry, and running out
    /// of the schedule gives up silently — the row just reads "no delivery info".
    /// Direct play has no job to probe. Clears any stale delivery up front so the
    /// window (and a re-probe after a track switch, where burn-in can flip the answer)
    /// reads "probing…" until the fresh result lands. DEBUG-only: since the seek gate
    /// stopped reading delivery, the `#if DEBUG` `DebugInfoOverlay` row is the sole
    /// consumer — a Release build must not spend per-session network fetches on it.
    func startDeliveryProbe(for resolved: ResolvedPlayback) {
        #if DEBUG
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil
        deliveryProbeExhausted = false
        guard resolved.method == .transcode else { return }
        let sessionID = resolved.playSessionID
        let fetch = fetchDelivery
        let schedule = Self.deliveryProbeSchedule
        deliveryProbeTask = Task { [weak self, clock] in
            for delay in schedule {
                do { try await clock.sleep(for: delay) } catch { return }
                if Task.isCancelled { return }
                if let delivery = await fetch(sessionID) {
                    if Task.isCancelled { return }
                    self?.transcodeDelivery = delivery
                    return
                }
            }
            if !Task.isCancelled { self?.deliveryProbeExhausted = true }
        }
        #endif
    }

    /// Whole milliseconds in `duration`. The reload's trace is a sequence of durations —
    /// encode kill, re-resolve, engine load — and a device log answers "which step was slow"
    /// only if each one is measured the same way.
    nonisolated static func millis(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

/// What the player measures about its own session: the startup stopwatch (the debug overlay's
/// `Startup:` row, and one retained `OpenRecord` per open that reached its first frame, shipped
/// in Release), and what the transcode job is doing to the video.
@Observable
@MainActor
final class SessionDiagnostics {
    /// Milliseconds on the player's clock from `engine.play()` dispatch to this session's FIRST
    /// `.playing` beat — the debug overlay's `Startup:` row (Plan C, AVKit startup
    /// tuning A/B). `nil` before the first beat lands and reset per session/reload
    /// (see `reset()`). Engine-agnostic: set for VLCKit sessions too, though
    /// only AVKit is presently tunable.
    private(set) var startupMillis: Int?

    /// What the live transcode job is ACTUALLY doing to the video (copy/remux vs
    /// re-encode) — the copy-vs-reencode signal `PlaybackInfo` can't give (the server
    /// reports `Transcode` for stream-copy jobs too; only the running session's
    /// `TranscodingInfo` distinguishes them, once ffmpeg has started). Nil until the
    /// probe lands (and on direct-play / SMB, which never probe; and in Release,
    /// where the probe never arms). DEBUG-display only — it feeds the delivery debug
    /// row. Cleared with the session; re-fetched after a track-switch rebuild, since a
    /// burn-in subtitle flips `isVideoDirect` false.
    private(set) var transcodeDelivery: TranscodeDelivery?
    /// True once the delivery probe's schedule ran out with no result — the debug row
    /// can say so instead of reading "probing…" forever. Reset on each new probe.
    private(set) var deliveryProbeExhausted = false
    /// The one-shot delivery probe for the current session — stored so session
    /// teardown cancels it (like `keepaliveTask`). Re-armed on each session's first
    /// `.playing` beat, which includes a track-switch rebuild.
    @ObservationIgnored private var deliveryProbeTask: Task<Void, Never>?

    /// The last open that reached `.playing`, as written to the retained log.
    private(set) var lastOpen: OpenRecord?

    private static let openLog = Log.retained(category: "PlayerOpen")

    /// `engine.play()` was dispatched on `engine`.
    private struct Dispatch {
        let at: Duration
        let engine: PlaybackEngineID
    }

    /// The one stopwatch both metrics read; the first `.playing` beat consumes it.
    ///
    /// An open (the user-visible wait from the player's start) walks `armed` → `resolved` →
    /// `dispatched`, and survives `reset()` and an AVKit→VLC reroute mid-open. A reload has no
    /// open and no route: its startup metric alone runs as `reloading`. Only `dispatched` can
    /// finish an open, and it can only be reached through `resolved`, so a record always has
    /// its resolve span and route.
    private enum Stopwatch {
        case idle
        case reloading(Dispatch)
        case armed(start: Duration, origin: OpenOrigin)
        case resolved(start: Duration, origin: OpenOrigin, resolve: Duration, route: OpenRoute)
        case dispatched(start: Duration, origin: OpenOrigin, resolve: Duration, route: OpenRoute, Dispatch)
    }

    @ObservationIgnored private var stopwatch = Stopwatch.idle

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

    /// `engine.play()` was dispatched on `engine`: start the clock the first `.playing` beat
    /// stops. A reroute dispatches again on the engine that will actually play. A dispatch with no
    /// route behind it is a reload's (or a path that never noted one), and measures no open.
    func armStartupClock(engine: PlaybackEngineID) {
        let dispatch = Dispatch(at: elapsed(), engine: engine)
        switch stopwatch {
        case .idle, .reloading, .armed:
            stopwatch = .reloading(dispatch)
        case .resolved(let start, let origin, let resolve, let route),
             .dispatched(let start, let origin, let resolve, let route, _):
            stopwatch = .dispatched(start: start, origin: origin, resolve: resolve, route: route, dispatch)
        }
    }

    /// The user asked to play. The outermost entry wins: `start(item:)` under `start(itemID:)`
    /// keeps the earlier anchor.
    func armOpen(origin: OpenOrigin = .tap) {
        switch stopwatch {
        case .idle: stopwatch = .armed(start: elapsed(), origin: origin)
        case .reloading, .armed, .resolved, .dispatched: break
        }
    }

    /// The open failed or was replaced: no record. A running startup clock is left alone.
    func cancelOpen() {
        switch stopwatch {
        case .armed, .resolved: stopwatch = .idle
        case .dispatched(_, _, _, _, let dispatch): stopwatch = .reloading(dispatch)
        case .idle, .reloading: break
        }
    }

    /// Runs the open's resolve inside its stopwatch and notes the route it chose, together, so an
    /// open cannot reach `.playing` with a resolve and no route. `resolve` covers, for Jellyfin,
    /// the PlaybackInfo negotiation; for SMB, the sidecar listing, container probe, resume lookup
    /// and bridge start.
    func timingResolve<T>(route: (T) -> OpenRoute, _ body: () async throws -> T) async rethrows -> T {
        let began = elapsed()
        let result = try await body()
        if case .armed(let start, let origin) = stopwatch {
            stopwatch = .resolved(start: start, origin: origin, resolve: elapsed() - began, route: route(result))
        }
        return result
    }

    /// A `.playing` beat landed. Only the session's first lands the metrics; it consumes the
    /// anchor, so a later `.playing` (resume-from-pause, post-stall) never overwrites them.
    func notePlaying() {
        let now = elapsed()
        switch stopwatch {
        case .idle, .armed, .resolved:
            return
        case .reloading(let dispatch):
            startupMillis = Self.millis(now - dispatch.at)
        case .dispatched(let start, let origin, let resolve, let route, let dispatch):
            startupMillis = Self.millis(now - dispatch.at)
            let record = OpenRecord(
                total: now - start, resolve: resolve, load: now - dispatch.at,
                route: route, engine: dispatch.engine, origin: origin
            )
            Self.openLog.notice(record.logLine)
            lastOpen = record
        }
        stopwatch = .idle
    }

    /// The session is over, or a reload opened a fresh one: the outgoing metric and delivery
    /// verdict must not linger, and a stale "exhausted" must not either — the debug row gates on
    /// it while `transcodeDelivery` is nil, and would read "no delivery info" for the whole
    /// window instead of "probing…" until the next session's first `.playing` beat re-probes.
    func reset() {
        switch stopwatch {
        case .reloading: stopwatch = .idle
        case .dispatched(let start, let origin, let resolve, let route, _):
            stopwatch = .resolved(start: start, origin: origin, resolve: resolve, route: route)
        case .idle, .armed, .resolved: break
        }
        startupMillis = nil
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil
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
    /// reads "probing…" until the fresh result lands. DEBUG-only: the `#if DEBUG`
    /// `DebugInfoOverlay` row is the sole consumer — a Release build must not spend
    /// per-session network fetches on it.
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

/// Why a player started opening a stream.
public enum OpenOrigin: String, Equatable, Sendable {
    /// The user asked to play.
    case tap
    /// The player moved to another episode.
    case advance
    /// The user retried a failed open.
    case retry
}

public enum OpenRoute: Equatable, Sendable {
    case smb(bridged: Bool)
    case jellyfin(PlaybackMethod)

    public var logFields: String {
        switch self {
        case .smb(let bridged): "source=smb transport=\(bridged ? "bridge" : "native")"
        case .jellyfin(.directPlay): "source=jellyfin transport=directPlay"
        case .jellyfin(.transcode): "source=jellyfin transport=transcode"
        }
    }
}

/// One open that reached its first frame: `total` runs from the player's start, `resolve` is the
/// network/probe wait before any engine exists, `load` is `engine.play()` to the first frame.
public struct OpenRecord: Equatable, Sendable {
    public let total: Duration
    public let resolve: Duration
    public let load: Duration
    public let route: OpenRoute
    public let engine: PlaybackEngineID
    public let origin: OpenOrigin

    public var logLine: String {
        let engineName = switch engine {
        case .avKit: "avkit"
        case .vlcKit: "vlc"
        }
        let timings = "\(SessionDiagnostics.millis(total))ms (resolve \(SessionDiagnostics.millis(resolve))ms, load \(SessionDiagnostics.millis(load))ms)"
        return "open → playing in \(timings) \(route.logFields) engine=\(engineName) origin=\(origin.rawValue)"
    }
}

import Foundation
import MediaPlayer
import Observation
import os
import CoreMedia
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

/// The active SMB/local session's resume-tracking state — see `PlayerViewModel.smbSession`.
/// Existence ⟺ there's a live SMB session with an id (non-optional `itemID`); Jellyfin
/// sessions leave it nil. Cleared as ONE value via `clearSMBSession()`.
private struct SMBSessionState {
    /// The playing item's identity — the `SMBResumeStore` key progress beats persist under.
    /// Set from `SMBPlaybackItem.itemID` in `start(smbItem:)`.
    var itemID: ItemID
    /// Whether `currentDuration` is a real container length rather than VLCKitEngine's
    /// read-rate estimate for an incomplete file. Gates the store's ≥95%-complete clear OFF
    /// when false — an estimate must never wipe real progress. Reset with the whole session,
    /// so a later Jellyfin/SMB session can't inherit a stale false. (`hasTrustworthyDuration`.)
    var hasTrustworthyDuration: Bool
    /// Last time a resume position was persisted — throttles the `.playing`/`.paused` beat
    /// writes to one per ~10s, mirroring the Jellyfin progress-report cadence.
    var lastResumeWrite: Date = .distantPast
    /// The in-flight throttled save spawned by `saveSMBResumeThrottled`, cancelled and
    /// replaced on each new save. A stale save must not outrun a terminal write: `stop()` and
    /// `.ended` await it (via `clearSMBSession()`) before their own save/clear, so a delayed
    /// beat can never land on the store actor AFTER the terminal write and resurrect a resume.
    var resumeSaveTask: Task<Void, Never>?
}

@Observable
@MainActor
final class PlayerViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case playing
        case failed(AppError)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.playing, .playing):
                return true
            case let (.failed(l), .failed(r)):
                return l.diagnosticDescription == r.diagnosticDescription
            default:
                return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var engine: (any PlaybackEngine)?
    var isPiPAvailable: Bool { engine?.capabilities.supportsPiP ?? false }
    var isVideoAirPlayAvailable: Bool { engine?.capabilities.supportsVideoAirPlay ?? false }

    /// PiP start/stop actions, pushed up from the video host once its
    /// PiP controller is ready (AVKit: `onPiPReady`; VLC: `VLCPictureInPictureDrawable`).
    /// Nil until a host mounts — so `startPiP()`/`stopPiP()` are safe no-ops in tests.
    var startPiPAction: (@MainActor () -> Void)?
    var stopPiPAction: (@MainActor () -> Void)?
    func startPiP() { startPiPAction?() }
    func stopPiP() { stopPiPAction?() }
    private(set) var availableAudioTracks: [AudioTrack] = []
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var selectedAudioTrack: AudioTrack? = nil
    private(set) var selectedSubtitleTrack: SubtitleTrack? = nil
    /// Parsed cues for a client-rendered subtitle that `SubtitleOverlayView` draws: the
    /// correctly-timed sidecar WebVTT used by the transcode path AND by direct-play
    /// EXTERNAL subs (VLC can't shape sidecar VTT on iOS). Empty when no such subtitle is
    /// active — including direct-play EMBEDDED subs, which the engine renders itself. This
    /// is how we sidestep the in-manifest WebVTT drift (jellyfin/jellyfin#16647).
    private(set) var activeSubtitleCues: [SubtitleCue] = []
    /// Manual timing nudge for client-rendered cues (`SubtitleOverlayView`), in
    /// milliseconds; positive shows them later. The engine's own retiming
    /// (`setSubtitleDelay`) doesn't reach these — they're drawn against the engine
    /// clock — so this is the escape hatch for the Jellyfin HLS transcode seek desync,
    /// where `currentTime` drifts ahead of the frames (the client has no independent
    /// clock to auto-correct it). Reset whenever the active sidecar changes.
    private(set) var clientSubtitleDelayMs: Int = 0
    private(set) var currentPosition: CMTime = .zero
    private(set) var currentDuration: CMTime = .zero

    /// The single source of truth for "do we have a real, scrubbable runtime?" — the player is
    /// interactive (`phase == .playing`) the instant frames render, but the timeline is only
    /// seekable once a length is known. Incomplete media (a truncated SMB file whose trailing
    /// moov atom isn't downloaded) plays with an `.indefinite` duration that never resolves;
    /// `CMTime.isNumeric` is false for `.indefinite`/`.invalid`, and the `> 0` rejects the `.zero`
    /// the duration inits to before the first beat. Every "is the duration usable?" check (the
    /// scrubber's seek guards, the progress bar's indeterminate affordance, chapter ticks) reads
    /// this one predicate so they can't drift.
    var hasKnownDuration: Bool {
        currentDuration.isNumeric && CMTimeGetSeconds(currentDuration) > 0
    }
    /// Absolute media time the contiguous buffer around the playhead extends to
    /// (from the engine's beats). Nil when the engine doesn't report it (VLC) or
    /// while a (re)load is buffering fresh.
    private(set) var bufferedTo: CMTime?

    /// 0...1 fraction of the duration the buffer extends to — the progress bar's
    /// middle "instant seek" layer. Seeks landing inside it complete without a
    /// server round-trip, so the bar shows the user where scrubbing is free.
    var bufferedFraction: Double? {
        guard let bufferedTo else { return nil }
        let dur = CMTimeGetSeconds(currentDuration)
        let end = CMTimeGetSeconds(bufferedTo)
        guard dur > 0, end.isFinite else { return nil }
        return min(max(end / dur, 0), 1)
    }
    /// Whether the engine is actively playing (vs paused). `phase` stays `.playing`
    /// while paused (the video surface stays on screen), so the play/pause button
    /// must read this — not `phase` — or it shows "pause" forever and can never resume.
    private(set) var isPlaying: Bool = false

    // MARK: - Player chrome (P4)

    /// The playing item's title — surfaced in the player's top bar. Episodes
    /// prepend their episode number (e.g. `"2. Winter Is Coming"`) so the HUD reads
    /// which episode is playing; movies/SMB show the bare title. `itemTitle` itself
    /// stays unprefixed — the Now Playing info center wants the clean episode name in
    /// its title field, the show goes elsewhere.
    var title: String {
        guard let episodeNumber else { return itemTitle }
        return "\(episodeNumber). \(itemTitle)"
    }

    /// Caption for the loading scrim. A transcode audio switch reloads the
    /// stream ("Switching audio · <track>"); a seek that re-anchors the transcode, or
    /// a mid-stream stall over a live frame, reads "Buffering"; a first play is
    /// "Loading video". The re-anchor seek reuses the track-switch reload (so it sets
    /// `isSwitchingTracks` too) — `isReanchoring` must win first, since a scrub is not
    /// an audio switch.
    var loaderTitle: String {
        if isReanchoring { return "Buffering" }
        if isSwitchingTracks { return "Switching audio" }
        if showsStallScrim { return "Buffering" }
        return "Loading video"
    }
    var loaderSubtitle: String? { isSwitchingTracks && !isReanchoring ? selectedAudioTrack?.displayName : nil }

    /// Mid-stream stall (engine waiting for media while the user's intent is
    /// "playing") — drives the light buffering scrim over the frozen frame.
    /// Debounced ~400ms so the sub-second waits of a healthy in-buffer seek
    /// don't flash the scrim; cleared edge-on by the next playing/paused beat.
    private(set) var isStalled = false
    private var stallDebounceTask: Task<Void, Never>?

    /// True when the mid-stream stall scrim should show: stalled while the
    /// surface is live (`phase == .playing`). A stall during the first load
    /// keeps the heavy "Loading" scrim instead — same spot, different flavor.
    var showsStallScrim: Bool { phase == .playing && isStalled }

    private func armStallDebounce() {
        guard !isStalled, stallDebounceTask == nil else { return }
        stallDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isStalled = true
            self?.stallDebounceTask = nil
        }
    }

    private func clearStall() {
        stallDebounceTask?.cancel()
        stallDebounceTask = nil
        isStalled = false
    }

    /// Which menu a track switch/failure concerns — audio and (since PGS burn-in)
    /// subtitle switches share the same re-resolve + failure-scrim machinery, so
    /// this is the one seam between the two instead of two near-identical copies.
    enum TrackPick: Equatable {
        case audio(AudioTrack)
        /// `nil` is Off — leaving an active burn-in for Off now re-resolves like any
        /// other subtitle pick (see `reloadSubtitleTranscode`), so its failure needs a
        /// representable "requested" pick too. Off has no `TrackID` (the menu's Off row
        /// carries none either — `SubtitleTrackMenu.offFocusKey`), hence `id` below.
        case subtitle(SubtitleTrack?)

        var id: TrackID? {
            switch self {
            case .audio(let track): track.id
            case .subtitle(let track): track?.id
            }
        }
        var displayName: String {
            switch self {
            case .audio(let track): track.displayName
            case .subtitle(let track): track?.displayName ?? "Off"
            }
        }
        /// The scrim title's noun ("Couldn't switch audio" / "…subtitles").
        var kindLabel: String {
            switch self {
            case .audio: "audio"
            case .subtitle: "subtitles"
            }
        }
    }

    /// A transcode track switch that failed AFTER playback safely resumed on the
    /// previous track (the design's silent fallback). Drives the "Couldn't switch
    /// audio"/"…subtitles" scrim: `retryFailedTrackSwitch()` re-attempts the same
    /// pick, `dismissTrackSwitchFailure()` keeps the current one. Nil when no failed
    /// switch is pending. Fatal failures (engine lost mid-reload) never set this —
    /// they go through `phase = .failed` and the general error scrim.
    struct TrackSwitchFailure {
        /// The track the user asked for — the retry target.
        let requested: TrackPick
        /// The track playback stayed on. Nil when the previous selection is unknown.
        let fallback: TrackPick?
        let error: AppError
    }
    private(set) var trackSwitchFailure: TrackSwitchFailure?

    /// Re-attempt the failed switch with the same track.
    func retryFailedTrackSwitch() async {
        guard let failure = trackSwitchFailure else { return }
        trackSwitchFailure = nil
        switch failure.requested {
        case .audio(let track): await selectAudioTrack(track)
        case .subtitle(let track): await selectSubtitleTrack(track)
        }
    }

    /// Keep the current (fallback) track and drop the failure scrim.
    func dismissTrackSwitchFailure() {
        trackSwitchFailure = nil
    }

    /// User-selected playback speed (1.0 = normal). Drives the speed chip.
    private(set) var playbackRate: Float = 1

    /// A concise format summary for the top bar, e.g. "4K · HDR · 7.1".
    /// Cached, not computed-per-read: `body` re-evaluates ~twice a second off the
    /// periodic time observer, and the derivation scans `resolved.mediaStreams`.
    /// Recomputed only when the stream resolves (`recomputeMediaSummary`).
    private(set) var mediaSummary: String?

    /// Wall-clock milliseconds from `engine.play()` dispatch to this session's FIRST
    /// `.playing` beat — the debug overlay's `Startup:` row (Plan C, AVKit startup
    /// tuning A/B). `nil` before the first beat lands and reset per session/reload
    /// (see `startupClockStart`). Engine-agnostic: set for VLCKit sessions too, though
    /// only AVKit is presently tunable.
    private(set) var startupMillis: Int?

    private func recomputeMediaSummary() {
        guard let resolved else { mediaSummary = nil; return }
        var parts: [String] = []
        if let video = resolved.mediaStreams.first(where: { $0.kind == .video }) {
            if let q = Self.qualityLabel(width: video.width, height: video.height) { parts.append(q) }
            if let r = Self.hdrLabel(video.videoRangeType ?? video.videoRange) { parts.append(r) }
        }
        let audioIndex = currentAudioStreamIndex ?? resolved.defaultAudioStreamIndex
        let audio = resolved.mediaStreams.first { $0.kind == .audio && $0.index == audioIndex }
            ?? resolved.mediaStreams.first { $0.kind == .audio }
        if let layout = TrackDisplay.channelLayout(audio?.channels) { parts.append(layout) }
        mediaSummary = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Set the playback speed and apply it to the live engine. Persists across
    /// pause/resume; re-applied to a fresh engine in `beginPlayback`.
    func setPlaybackRate(_ rate: Float) async {
        playbackRate = rate
        await engine?.setRate(rate)
    }

    /// Chapter markers for the playing item (movie/episode only). Empty when the
    /// server reported none, or for the unsupported series/season cases.
    var chapters: [Chapter] {
        switch playingItem {
        case .movie(let d): return d.chapters
        case .episode(let d): return d.chapters
        case .series, .season, .none: return []
        }
    }

    /// Chapter start fractions (0...1) of the current duration — the progress bars'
    /// tick positions on every platform. Empty until the duration is known.
    /// Cached, not computed-per-read (same reason as `mediaSummary`): the scrubber body
    /// re-evaluates ~twice a second off the periodic position beat, and this maps every
    /// chapter through a divide. Recomputed only when the chapter set (`playingItem`) or
    /// the duration actually changes — see `recomputeChapterFractions` / `applyDuration`.
    private(set) var chapterFractions: [Double] = []

    private func recomputeChapterFractions() {
        let dur = CMTimeGetSeconds(currentDuration)
        guard dur > 0 else { chapterFractions = []; return }
        chapterFractions = chapters.map { chapter in
            let c = chapter.start.components
            let s = Double(c.seconds) + Double(c.attoseconds) / 1e18
            return min(max(s / dur, 0), 1)
        }
    }

    /// Sets `currentDuration` and refreshes the derived `chapterFractions` ONLY when the
    /// value actually changes. The duration lands once per asset and then repeats
    /// unchanged on every position beat (~2/s), so gating the recompute on a real change
    /// is what keeps this off the per-beat path. Every duration write goes through here.
    private func applyDuration(_ duration: CMTime) {
        guard duration != currentDuration else { return }
        currentDuration = duration
        recomputeChapterFractions()
    }

    /// The chapter containing `atSeconds`, formatted "Chapter N · Name" — the scrub
    /// bubble's caption on every platform. Nil when the item has no chapters.
    func chapterTitle(atSeconds: Double) -> String? {
        let chapters = chapters
        guard !chapters.isEmpty else { return nil }
        func startSeconds(_ chapter: Chapter) -> Double {
            let c = chapter.start.components
            return Double(c.seconds) + Double(c.attoseconds) / 1e18
        }
        let current = chapters.last(where: { startSeconds($0) <= atSeconds }) ?? chapters[0]
        if let name = current.name, !name.isEmpty {
            return "Chapter \(current.index + 1) · \(name)"
        }
        return "Chapter \(current.index + 1)"
    }

    /// Seek to a chapter's start. Reconstruct the full sub-second offset (the
    /// fractional part lives in `attoseconds`) — `.seconds` alone would land a
    /// chapter with a fractional start up to ~1s early, inside the prior chapter.
    func seekToChapter(_ chapter: Chapter) async {
        let c = chapter.start.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        await seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Optimistic transport toggle from the play/pause button. Flips to the
    /// opposite of the current intent via `setPlaying`.
    func togglePlayPause() {
        setPlaying(!isPlaying)
    }

    /// Drive the transport to an explicit play state NOW so the play/pause glyph swaps on the
    /// tap itself, then command the engine. The next engine beat (.playing/.paused) confirms or
    /// corrects — `handle()` stays the source of truth; this only removes the tap→engine→beat
    /// round-trip from the button (play especially: AVPlayer emits no beat until its transport
    /// actually flips, hundreds of ms on a transcode).
    ///
    /// Shared by the button (`togglePlayPause`) AND the Now Playing remote commands so EVERY
    /// explicit transport intent clears the scrub latch and wins: a remote pause/play landing in
    /// the scrub-commit window must not be swallowed by `scrubResumeIntent` (which pins `isPlaying`
    /// across the scrub's own transient beats) and strand the glyph on the stale pre-scrub state —
    /// AVKit emits no further beat while paused, so it wouldn't self-heal.
    ///
    /// Spam-safe by cancel-previous coalescing: each call retargets ONE `transportTask`, so a
    /// burst flips the glyph with every press (parity — instant, like the system player) but only
    /// the LAST intent is still alive to command the engine; stale commands die before their
    /// `await`. The synchronous flip happens before any suspension, so intent order can't interleave.
    ///
    /// The scrub and reducer pause/resume paths must KEEP commanding the engine directly: they
    /// capture `isPlaying` as resume intent, and an optimistic write there would corrupt the capture.
    func setPlaying(_ playing: Bool) {
        guard engine != nil else { return }
        scrubResumeIntent = nil   // an explicit transport command overrides any pending scrub latch
        isPlaying = playing
        transportTask?.cancel()
        transportTask = Task {
            // Re-read the engine at execution time: a pending command after
            // stop() must no-op, not poke a torn-down engine.
            guard !Task.isCancelled, let engine else { return }
            if playing { await engine.play() } else { await engine.pause() }
        }
    }

    /// Pins the transport state across a scrub commit. The drag-scrub pauses the engine to hold
    /// the still frame and re-plays it on release, so the engine emits transient `.paused` beats
    /// — the drag pause, then `seek()` re-reading the now-paused `isPlaying` — followed by the
    /// resume `.playing` beat up to a poll (500ms) later. Honoring those beats flashes the glyph
    /// to "play" for that gap (the bug a one-shot optimistic write couldn't win, since the stale
    /// `.paused` beat is consumed *after* it). While an intent is latched, `handle()` pins
    /// `isPlaying` to it and ignores the mismatched transient beats; the scrub commit clears the
    /// latch (`endScrubLatch`) once it settles. nil = not scrubbing, so beats drive `isPlaying`
    /// directly. Touch-drag only: the tvOS/VoiceOver seek paths don't pause the engine, so
    /// `seek()` keeps `isPlaying == true` and they never arm this.
    private var scrubResumeIntent: Bool?

    /// Arm the scrub transport latch with the user's pre-scrub play state. Re-armed on every
    /// drag press (with the chain-start play state) so a re-drag mid-commit can't strand it.
    /// See `scrubResumeIntent`.
    func beginScrubLatch(resumePlaying: Bool) {
        scrubResumeIntent = resumePlaying
        isPlaying = resumePlaying
    }

    /// Release the scrub transport latch once the commit has settled (seek + optional resume +
    /// position converged). Explicit — not auto-cleared on a matching beat — so a `.playing` beat
    /// already queued when the drag began can't drop the latch early and re-expose the flicker.
    func endScrubLatch() {
        scrubResumeIntent = nil
    }

    private let deviceProfileBuilder: DeviceProfileBuilder
    private let playbackInfo: any PlaybackReporting
    private let resolve: ResolveCall
    private let engineFactory: @MainActor @Sendable (PlaybackEngineID) -> any PlaybackEngine
    private let audioSession: any AudioSessionControlling
    /// Fetches an item's full detail (`ItemDetail`) from its id — used by the
    /// direct-play entry `start(itemID:)`. Defaulted so existing `start(item:)`
    /// call sites/tests that already hold the detail don't have to provide it.
    private let fetchDetail: @Sendable (ItemID) async throws -> ItemDetail
    /// Fetches sidecar subtitle bytes. Injectable so tests feed canned WebVTT
    /// without a network round-trip; production reads the authed VTT URL.
    private let subtitleFetch: @Sendable (URL) async -> Data?
    /// The local resume store SMB progress beats persist into. Injectable so tests read/write
    /// an isolated suite-backed store instead of `UserDefaults.standard`.
    private let smbResumeStore: SMBResumeStore
    /// Persists a track pick into the user's server-side language preferences
    /// (PlaybackInfoService.rememberTrackSelection in production). Defaulted to
    /// a no-op so tests and previews don't need the wiring.
    private let rememberTrackSelection: @Sendable (TrackSelectionUpdate) async -> Void
    /// Best-effort fetch of intro/outro segments for an item (empty on error or
    /// when the server has no provider). Defaulted to empty so tests/previews need
    /// no wiring.
    private let fetchSegments: @Sendable (ItemID) async -> [MediaSegment]
    /// Best-effort fetch of an episode's previous/next neighbors — args are
    /// (seriesID, episodeID), `.none` on error or for non-episodes. Defaulted.
    private let fetchAdjacent: @Sendable (ItemID, ItemID) async -> AdjacentEpisodes
    /// Ping cadence for `keepaliveTask` — half the server's 60s idle kill
    /// timeout in production; injectable so tests don't wait 30s for a beat.
    private let keepaliveInterval: Duration
    /// Probes the live transcode's copy-vs-reencode delivery (`TranscodeDelivery`)
    /// by play-session id. Defaulted to a nil-returning no-op so SMB, previews, and
    /// tests that don't care need no wiring; the Jellyfin path injects
    /// `PlaybackInfoService.transcodingDelivery`. Nil = ffmpeg hasn't started / no
    /// matching session yet — the probe treats it as "ask again".
    private let fetchDelivery: @Sendable (String) async -> TranscodeDelivery?
    /// Wait-then-fetch schedule for the delivery probe: one sleep+fetch per entry, in
    /// order, until a non-nil result lands or the schedule runs out. Production waits
    /// ~2s after the first `.playing` beat (ffmpeg starts lazily, `TranscodingInfo`
    /// isn't populated instantly), then retries once at +5s before giving up silently;
    /// injectable so tests don't wait seconds.
    private let deliveryProbeSchedule: [Duration]

    private var stateTask: Task<Void, Never>?
    private var subtitleFetchTask: Task<Void, Never>?
    /// The in-flight play/pause command — retargeted on every toggle so a tap
    /// burst coalesces to the last intent (see `togglePlayPause`).
    private var transportTask: Task<Void, Never>?
    /// Keepalive for the server's transcode job: pings the play session on a
    /// timer so the 60s idle kill never fires while the player is mounted.
    /// Segment requests stop once a PAUSED player's buffer fills, and progress
    /// beats stop with them (the periodic observer is quiet at rate 0) — so a
    /// pause >60s would otherwise get the job AND its segments deleted, and
    /// resume would pay a cold ffmpeg respawn (the endless-buffering wedge).
    /// Runs while playing too: redundant next to segment traffic, but immune
    /// to the player's fetch cadence. Transcode sessions only.
    private var keepaliveTask: Task<Void, Never>?
    private var resolved: ResolvedPlayback?
    /// Source-agnostic subtitle URL map: stream-index → sidecar URL. Jellyfin
    /// populates it from `resolved.subtitleStreamURLs` in `beginPlayback`; the
    /// SMB path (Task 10) will populate it from the filename-matched sibling
    /// resolver before loading the engine. Both paths produce WebVTT or SRT URLs
    /// that `loadSidecarSubtitle` fetches and parses.
    private var subtitleURLs: [Int: URL] = [:]
    /// Synthetic external subtitle tracks for the SMB path (`resolved` is nil there, so
    /// the Jellyfin `externalSubtitleTracks(from: resolved)` machinery can't build them).
    /// Populated in `start(smbItem:)` and re-appended to the engine's inventory on every
    /// `.ready` beat — the engine reports only EMBEDDED tracks, so without this the sidecar
    /// subs would be dropped the moment the engine's inventory lands.
    private var smbExternalSubtitleTracks: [SubtitleTrack] = []
    private var didReportStart = false
    private var didReportStopped = false
    /// Set at `engine.play()` dispatch in `loadAndPlay`, consumed (cleared) by the
    /// first `.playing` beat this session — see `startupMillis`. `nil` after
    /// consumption so a later `.playing` beat (pause/resume, mid-stream rebuffer)
    /// never overwrites the metric.
    private var startupClockStart: ContinuousClock.Instant?
    /// Whether this session's server-side encoding was already killed. NOT
    /// gated on `didReportStart` like the stop report — the transcode job
    /// exists from resolve time, so a session that wedged before its first
    /// `.playing` beat still has a job to kill on exit.
    private var didStopEncoding = false
    /// Exit was requested (`beginExit()`/`stop()`): the in-flight start path bails
    /// at its next checkpoint instead of resurrecting playback after dismissal.
    private var isExiting = false
    /// `stop()` already ran — the second caller is a no-op (exit fires it from the
    /// dismiss trigger AND from `onDisappear` as a backstop).
    private var didStop = false
    /// True while `start()` is executing. The HUD is live during loading, so a track
    /// pick could otherwise land in the sliver where `beginPlayback` is suspended
    /// (engine.load) and race it with a second resolve/engine.
    private var isStartingPlayback = false
    /// Server language preferences were applied to this item's initial tracks —
    /// once per `start`, never on track-switch reloads or duplicate `.ready` beats.
    private var didApplyPreferredTracks = false
    /// True only while a transcode track switch is reloading the (reused) engine.
    /// Gates `handle(_:)` so the outgoing stream's trailing beats are ignored — a
    /// stale `.playing` would otherwise claim the new session's `reportStart`.
    /// Also drives the loader caption (a switch reads "Switching audio", a first
    /// play reads "Loading").
    private(set) var isSwitchingTracks = false
    private var lastPosition: CMTime = .zero
    private let nowPlaying = NowPlayingController()
    private var itemTitle: String = ""
    /// HUD-only episode number prepended to `title` (e.g. `"2. <name>"`); nil for
    /// movies and SMB. Reset on every `start*` so an episode→movie swap clears it.
    private var episodeNumber: Int?

    // Transcode track switching: the server bakes one audio + only text subs
    // into a transcode, so switching tracks means re-resolving the stream around
    // a different source index. We keep the item + the current indices to rebuild.
    private var playingItem: ItemDetail?
    /// The id requested via `start(itemID:)`, kept so `retry()` can re-fetch when
    /// the original failure was the detail fetch itself (no `playingItem` yet).
    private var pendingItemID: ItemID?
    /// The SMB resolve closure for the current local session (nil for Jellyfin), kept so
    /// `retry()` can replay the SMB path — which sets neither `playingItem` nor `pendingItemID`.
    private var smbResolve: (() async throws -> SMBPlaybackItem)?
    /// Tears down the SMB HTTP bridge + its reader when the current session ends (bridge route
    /// only; nil on the VLC route and every Jellyfin session). An orphaned bridge holds an SMB
    /// connection and a LAN-reachable file URL, so it must die with the session — invoked +
    /// nil'd in `stop()`, `tearDownEngine()`, and every `start(smbItem:)` failure catch.
    private var smbCleanup: (@Sendable () async -> Void)?
    /// The active SMB/local session's resume-tracking state, folded into one value so the
    /// "reset the trust bit wherever the item id clears" invariant is STRUCTURAL: clearing
    /// the session (`clearSMBSession()`) drops the id, the trust bit, and the throttle clock
    /// together, and awaits the in-flight save — they can't drift apart. Nil for Jellyfin
    /// sessions (the server owns their resume) and until `start(smbItem:)` sets it.
    ///
    /// The SMB HTTP-bridge cleanup (`smbCleanup`) is deliberately NOT folded in: it's armed
    /// earlier (during resolve, before the id exists) and torn down later (in `stop()`, AFTER
    /// `engine.teardown()`, so the engine finishes reading the bridge), so a single-clear path
    /// couldn't reproduce its ordering — it keeps its own lifecycle above.
    private var smbSession: SMBSessionState?
    private var currentAudioStreamIndex: Int?
    private var currentSubtitleStreamIndex: Int?

    // Transcode seek re-anchoring: an out-of-buffer seek re-resolves a fresh transcode
    // at the target (see `seek(to:)`). The newest target wins, drained single-flight so
    // a scrub past the buffer can't stack reloads or strand on a stale position.
    private var pendingReanchorTarget: CMTime?
    private var isReanchoring = false

    /// What the live transcode job is ACTUALLY doing to the video (copy/remux vs
    /// re-encode) — the copy-vs-reencode signal `PlaybackInfo` can't give (the server
    /// reports `Transcode` for stream-copy jobs too; only the running session's
    /// `TranscodingInfo` distinguishes them, once ffmpeg has started). Nil until the
    /// probe lands (and on direct-play / SMB, which never probe). Drives the seek
    /// strategy — a proven video-copy seeks in-stream — and the debug delivery row.
    /// Cleared with the session; re-fetched after a track-switch rebuild, since a
    /// burn-in subtitle flips `isVideoDirect` false.
    private(set) var transcodeDelivery: TranscodeDelivery?
    /// True once the delivery probe's schedule ran out with no result — the debug row
    /// can say so instead of reading "probing…" forever. Reset on each new probe.
    private(set) var deliveryProbeExhausted = false
    /// The one-shot delivery probe for the current session — stored so session
    /// teardown cancels it (like `keepaliveTask`). Re-armed on each session's first
    /// `.playing` beat, which includes a track-switch rebuild.
    private var deliveryProbeTask: Task<Void, Never>?

    /// The resolve surface, narrowed so the integration test can inject a stub
    /// without standing up a full PlaybackInfoService. Mirrors
    /// PlaybackInfoService.resolve(item:capabilities:startTime:audioStreamIndex:subtitleStreamIndex:).
    /// The two indices are nil on first play (server default) and set when the
    /// user switches a track on the transcode path.
    typealias ResolveCall = @Sendable (ItemID, DeviceCapabilities, CMTime?, Int?, Int?) async throws -> ResolvedPlayback

    init(
        deviceProfileBuilder: DeviceProfileBuilder,
        playbackInfo: any PlaybackReporting,
        resolve: @escaping ResolveCall,
        engineFactory: @escaping @MainActor @Sendable (PlaybackEngineID) -> any PlaybackEngine,
        audioSession: any AudioSessionControlling,
        fetchDetail: @escaping @Sendable (ItemID) async throws -> ItemDetail = { _ in
            throw AppError.playback(.unsupportedFormat)
        },
        subtitleFetch: @escaping @Sendable (URL) async -> Data? = { try? await URLSession.shared.data(from: $0).0 },
        rememberTrackSelection: @escaping @Sendable (TrackSelectionUpdate) async -> Void = { _ in },
        fetchSegments: @escaping @Sendable (ItemID) async -> [MediaSegment] = { _ in [] },
        fetchAdjacent: @escaping @Sendable (ItemID, ItemID) async -> AdjacentEpisodes = { _, _ in .none },
        keepaliveInterval: Duration = .seconds(30),
        fetchDelivery: @escaping @Sendable (String) async -> TranscodeDelivery? = { _ in nil },
        deliveryProbeSchedule: [Duration] = [.seconds(2), .seconds(5)],
        smbResumeStore: SMBResumeStore = .shared
    ) {
        self.deviceProfileBuilder = deviceProfileBuilder
        self.playbackInfo = playbackInfo
        self.resolve = resolve
        self.engineFactory = engineFactory
        self.audioSession = audioSession
        self.fetchDetail = fetchDetail
        self.subtitleFetch = subtitleFetch
        self.rememberTrackSelection = rememberTrackSelection
        self.fetchSegments = fetchSegments
        self.fetchAdjacent = fetchAdjacent
        self.keepaliveInterval = keepaliveInterval
        self.fetchDelivery = fetchDelivery
        self.deliveryProbeSchedule = deliveryProbeSchedule
        self.smbResumeStore = smbResumeStore
    }

    isolated deinit {
        // Match the JellyfinSearchViewModel teardown discipline: the consumer
        // Task is stored on the VM, so cancel it on the MainActor before
        // release. The engine's stream finishes on teardown() (called from
        // stop()); cancelling here makes teardown immediate if stop() was
        // never reached.
        stateTask?.cancel()
        subtitleFetchTask?.cancel()
        stallDebounceTask?.cancel()
        keepaliveTask?.cancel()
        deliveryProbeTask?.cancel()
        segmentsTask?.cancel()
    }

    // MARK: - Skip segments & episode succession

    /// Intro/outro markers for the playing item — empty when the server has no
    /// segment provider, which is the normal "no skip UI" case, never an error.
    private(set) var segments: [MediaSegment] = []
    /// Previous/next episode in airing order (`.none` for movies and at the
    /// series' first/last episode). Source for the prev/next buttons + autoplay.
    private(set) var adjacentEpisodes: AdjacentEpisodes = .none
    private var segmentsTask: Task<Void, Never>?
    /// Serializes episode swaps so a double-press — or an auto-advance racing a
    /// manual Next — can't kick off two overlapping reloads.
    private var isAdvancing = false

    var nextEpisode: Episode? { adjacentEpisodes.next }
    var previousEpisode: Episode? { adjacentEpisodes.previous }
    /// Whether the playing item is episodic (part of a series), so the prev/next
    /// transport is meaningful. False for movies — the centre cluster then shows
    /// play/pause alone. Set once per item from its type and stable across an
    /// episode→episode swap (both episodic), so the always-mounted prev/next buttons
    /// never unmount mid-press on tvOS.
    private(set) var supportsEpisodeNavigation = false
    /// Flips true when a natural end-of-video has nowhere to advance (a movie or a
    /// series finale). The view dismisses on it — same exit path as the Close/▼
    /// chevron — instead of stranding a paused glyph on the final frame.
    private(set) var playbackDidComplete = false

    /// The actionable segment the playhead currently sits inside (intro/recap/
    /// outro), or nil. Computed off the position beats, so the overlay button
    /// tracks the playhead with no extra timer.
    var activeSegment: MediaSegment? {
        guard phase == .playing, !segments.isEmpty else { return nil }
        let seconds = CMTimeGetSeconds(currentPosition)
        guard seconds.isFinite else { return nil }
        return segments.first { $0.kind.playerAction != nil && $0.contains(seconds: seconds) }
    }

    /// What the contextual overlay button offers right now, if anything: Skip for
    /// an intro/recap; Next Episode for an outro **only when a next episode
    /// exists** (otherwise the outro plays out and nothing shows).
    enum SegmentPrompt: Equatable {
        case skip(MediaSegment)
        case nextEpisode(MediaSegment)
        /// The segment this prompt is for, independent of its action.
        var segment: MediaSegment {
            switch self { case .skip(let s), .nextEpisode(let s): s }
        }
    }
    var segmentPrompt: SegmentPrompt? {
        guard let segment = activeSegment, let action = segment.kind.playerAction else { return nil }
        switch action {
        case .skip: return .skip(segment)
        case .nextEpisode: return nextEpisode != nil ? .nextEpisode(segment) : nil
        }
    }
    /// The id of the segment the contextual prompt is for right now, or nil. The single
    /// source for the one-shot suppression key — read by both `PlayerSegmentPrompt` and
    /// the tvOS `send` pipeline, so the switch-on-`segmentPrompt` lives in one place.
    var activeSegmentID: String? { segmentPrompt?.segment.id }

    /// Seek just past the active intro/recap and keep playing.
    func skipActiveSegment() async {
        guard let segment = activeSegment, segment.kind.playerAction == .skip else { return }
        await seek(to: CMTime(seconds: segment.endSeconds, preferredTimescale: 600))
    }

    /// Play the next episode now (the outro button, or the prev/next transport).
    func playNextEpisode() async {
        guard let next = adjacentEpisodes.next else { return }
        await replacePlayback(with: next.id)
    }

    /// Play the previous episode now (the prev transport button).
    func playPreviousEpisode() async {
        guard let previous = adjacentEpisodes.previous else { return }
        await replacePlayback(with: previous.id)
    }

    /// Whether a natural end-of-video should roll into the next episode: a next episode
    /// exists and the player is neither exiting nor already torn down. No-op for movies
    /// and finales. Read synchronously at `.ended` to capture the advance target and
    /// raise the loading veil before the paused scrim can flash.
    private var canAutoAdvance: Bool { !isExiting && !didStop && adjacentEpisodes.next != nil }

    /// Tears the current session down and replays this same player surface with a
    /// different item — the in-player episode handoff. Reuses `retry()`'s reset
    /// sequence (closes the encode job, clears the per-session fences) so the new
    /// episode starts clean on the reused view model.
    private func replacePlayback(with id: ItemID) async {
        guard !isAdvancing, !isExiting else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        await resetForReplay()
        await start(itemID: id)
    }

    /// Best-effort fetch of intro/outro segments + the prev/next episode for the
    /// item that just started. Never blocks or fails playback; errors resolve to
    /// no segments / no neighbors. Runs concurrently with the playback resolve.
    private func loadSegmentsAndNeighbors(for item: ItemDetail) {
        segments = []
        adjacentEpisodes = .none
        playbackDidComplete = false
        segmentsTask?.cancel()
        let itemID = item.id
        let episode: (series: ItemID, id: ItemID)?
        switch item {
        case .episode(let detail): episode = (detail.episode.seriesID, detail.episode.id)
        case .movie, .series, .season: episode = nil
        }
        // Stable for the whole session (only flips on the initial movie-vs-episode load,
        // never during an episode→episode swap), so the centre cluster can drop prev/next
        // for movies without ever unmounting a focused button on tvOS.
        supportsEpisodeNavigation = episode != nil
        segmentsTask = Task { [weak self, fetchSegments, fetchAdjacent] in
            async let segmentsResult = fetchSegments(itemID)
            var neighbors = AdjacentEpisodes.none
            if let episode {
                neighbors = await fetchAdjacent(episode.series, episode.id)
            }
            let resolvedSegments = await segmentsResult
            guard !Task.isCancelled else { return }
            self?.segments = resolvedSegments
            self?.adjacentEpisodes = neighbors
        }
    }

    /// Direct-play entry: fetch the item's detail, then play. The frosted reload
    /// cover stays up through the fetch (phase == .loading), so there's no separate
    /// spinner. Used when a screen has only the item id (an episode tapped in Home /
    /// Search / a library / a season list) — no detail screen in between.
    func start(itemID: ItemID) async {
        phase = .loading
        pendingItemID = itemID
        do {
            let detail = try await fetchDetail(itemID)
            try checkStillActive()
            await start(item: detail)
        } catch is CancellationError {
            // Exit raced the detail fetch — the view is gone; nothing to surface.
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            Log.playback.error("item detail fetch failed: \(error.networkDiagnostic)")
            phase = .failed(.unexpected("couldn't load item", underlying: AnySendableError(error)))
        }
    }

    func start(item: ItemDetail) async {
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        phase = .loading
        didApplyPreferredTracks = false
        playingItem = item
        // The chapter set just changed; refresh the derived fractions against whatever
        // duration is known (still the previous item's during an episode→episode swap —
        // the next duration beat corrects it, and an equal duration is already right).
        recomputeChapterFractions()
        let positionTicks: Int64
        let runtime: Duration?
        switch item {
        case .movie(let d):
            positionTicks = d.movie.userData.playbackPositionTicks
            runtime = d.movie.runtime
            itemTitle = d.movie.title
            episodeNumber = nil
        case .episode(let d):
            positionTicks = d.episode.userData.playbackPositionTicks
            runtime = d.episode.runtime
            itemTitle = d.episode.name
            episodeNumber = d.episode.indexNumber
        case .series, .season:
            phase = .failed(.playback(.unsupportedFormat))
            return
        }

        // Fire-and-forget alongside the resolve: best-effort, never gates playback.
        loadSegmentsAndNeighbors(for: item)

        do {
            do {
                try await audioSession.activate()
            } catch {
                // An audio-session config failure is not a connectivity problem;
                // map it to a distinct case and log the real error so on-device
                // failures leave a trail (the bare AVAudioSession NSError is not
                // an AppError, so it would otherwise fall into the generic catch
                // and be mislabeled as "Couldn't reach the file").
                Log.playback.error("audio session activate failed: \(error.networkDiagnostic)")
                throw AppError.playback(.audioSessionFailed)
            }
            let resumeTime = ResumePolicy.resumeStartTime(positionTicks: positionTicks, runtime: runtime)
            try await beginPlayback(
                item: item,
                startTime: resumeTime,
                audioStreamIndex: nil,
                subtitleStreamIndex: nil
            )
        } catch is CancellationError {
            // Exit raced the start path. stop() owns the real teardown; just make
            // sure the audio session isn't left active if stop() completed before
            // activate() did (deactivate is idempotent).
            await audioSession.deactivate()
        } catch let error as AppError {
            phase = .failed(error)
            await audioSession.deactivate()
        } catch {
            // A non-AppError reaching here is genuinely unexpected (resolve()
            // already maps its failures to AppError). Log it and preserve the
            // underlying error in diagnostics instead of mislabeling it as a
            // network problem.
            Log.playback.error("playback start failed (unmapped): \(error.networkDiagnostic)")
            phase = .failed(.unexpected("playback start failed", underlying: AnySendableError(error)))
            await audioSession.deactivate()
        }
    }

    /// SMB/local presentation entry: raise the loading veil, resolve the
    /// `SMBPlaybackItem` (Keychain + sidecar subs) off the tap, then delegate to
    /// `start(smbItem:)`. The resolve is the long off-tap step — the analog of the
    /// Jellyfin `start(itemID:)` detail fetch — so a failure here lands on the same
    /// failure scrim instead of silently no-op'ing the video.
    ///
    /// Delegation, not duplication: `start(smbItem:)` owns the audio-session
    /// activation, `isStartingPlayback`, and the real `loadAndPlay`. This method only
    /// owns the pre-resolve veil + the resolve's own error mapping, so the audio
    /// session is never double-activated and `phase` is managed in one place per step.
    func start(resolvingSMB resolve: @escaping () async throws -> SMBPlaybackItem) async {
        phase = .loading
        // Kept so the failure scrim's "Try again" can replay the SMB path (retry() otherwise
        // reads only the Jellyfin playingItem/pendingItemID, which this path never sets).
        smbResolve = resolve
        do {
            let item = try await resolve()
            // Stash the bridge cleanup BEFORE the exit fence below: `resolve()` already
            // started the bridge (bridge route), and `checkStillActive()` throws when a
            // dismissal landed in the resolve window (the common exit case). Stashing here
            // means the live bridge is reachable — the `stop()` backstop (onDisappear always
            // runs it) reads this property — instead of being dropped un-reaped. `start(smbItem:)`
            // re-stashes the same value; idempotent.
            smbCleanup = item.cleanup
            // The resolve is the off-tap window an exit usually lands in — bail before
            // delegating so a dismissed player can't start audio. `start(smbItem:)`
            // re-checks after activating the session.
            try checkStillActive()
            await start(smbItem: item)
        } catch is CancellationError {
            // Exit raced the resolve — the view is gone. Reap the bridge we just stashed:
            // if `stop()` already ran (onDisappear backstop firing during the resolve), it
            // reaped nothing — `smbCleanup` was still nil then — and won't run again (its
            // `didStop` guard), so the bridge would strand. `tearDownSMBBridge()` is idempotent
            // (nil-before-await), so it's safe even if a concurrent `stop()` also reaps it.
            await tearDownSMBBridge()
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            Log.playback.error("SMB resolve failed: \(error.networkDiagnostic)")
            phase = .failed(.unexpected("couldn't load file", underlying: AnySendableError(error)))
        }
    }

    /// SMB/local direct-play entry: play a local file by building a `PlayableAsset`
    /// DIRECTLY — no Jellyfin network resolve, no `DeviceProfile`, no
    /// `mediaSourceID`/`playSessionID`, no progress reporting. The caller (Task 11)
    /// pre-resolves everything (the `smb://` URL, credential options from the Keychain,
    /// sibling subtitle URLs), so the VM stays decoupled from the SMB layer.
    ///
    /// `resolved` deliberately stays nil: the beat handler's `if let resolved`
    /// blocks then skip all Jellyfin reporting, so a local session never reports
    /// progress to a server it has none of. The libVLC `smb://` path is the
    /// validated primary (the spike passed), so the asset routes to VLCKit via
    /// `hints.scheme == "smb"`.
    func start(smbItem: SMBPlaybackItem) async {
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        phase = .loading
        itemTitle = smbItem.title
        episodeNumber = nil
        // No Jellyfin item: skip resolve, DeviceProfile, keepalive, segments, and
        // neighbor lookups (all server features). `resolved` stays nil.
        //
        // Stashed up front (before the first throw point): the resolver already started the
        // bridge, so ANY failure below — audio-session, an exit-during-load fence, or the load
        // itself — must be able to tear it down. `stop()` is the backstop (onDisappear always
        // calls it); the `.failed` catches below clean up explicitly for the no-exit failures.
        smbCleanup = smbItem.cleanup
        // The local-resume session: progress beats + stop()'s final write persist positions
        // under `itemID` (exactly where the resolver's startTime came from);
        // `hasTrustworthyDuration` gates the store's 95%-complete clear (see the type doc).
        smbSession = SMBSessionState(itemID: smbItem.itemID,
                                     hasTrustworthyDuration: smbItem.hasTrustworthyDuration)
        do {
            do {
                try await audioSession.activate()
            } catch {
                Log.playback.error("audio session activate failed: \(error.networkDiagnostic)")
                throw AppError.playback(.audioSessionFailed)
            }
            try checkStillActive()
            // Sidecar subs are already filename-matched by the caller; surface them so
            // `loadSidecarSubtitle` finds the URL by index, exactly like the Jellyfin
            // path's `subtitleURLs = resolved.subtitleStreamURLs`.
            subtitleURLs = smbItem.subtitleURLs
            // Surface those sidecars as selectable menu entries NOW (before the engine's
            // embedded inventory lands on .ready), with the resolver's labels. The `.ready`
            // merge re-appends these to the engine's embedded subs so they survive it —
            // the Jellyfin `externalSubtitleTracks(from: resolved)` path is nil-`resolved`
            // on SMB, so this SMB-shaped overload stands in for it.
            smbExternalSubtitleTracks = Self.externalSubtitleTracks(
                urls: smbItem.subtitleURLs, labels: smbItem.subtitleLabels
            )
            availableSubtitleTracks = smbExternalSubtitleTracks
            // Materialized off-main (the first touch writes font files) so embedded
            // ASS/SSA subs still render under VLC — same source as the Jellyfin asset.
            let fonts = await SubtitleFontLocator.resolved()
            let asset = PlayableAsset(
                url: smbItem.url,
                headers: nil,
                // Probe-derived: scheme "http" (+ container/codecs) routes a bridged file to
                // AVKit, scheme "smb" keeps it on VLC. The resolver owns this decision.
                hints: smbItem.hints,
                startTime: smbItem.startTime,
                mediaStreams: [],
                defaultAudioStreamIndex: nil,
                defaultSubtitleStreamIndex: nil,
                subtitleFontURL: fonts?.primaryFile,
                subtitleFontsDirectoryURL: fonts?.directory,
                vlcOptions: smbItem.vlcOptions
            )
            try await loadAndPlay(asset, reusingEngine: false)
        } catch is CancellationError {
            // Exit fence: the player is dismissing, so `stop()` (onDisappear backstop) owns the
            // bridge teardown — don't race it here.
            await audioSession.deactivate()
        } catch let error as AppError {
            phase = .failed(error)
            await tearDownSMBBridge()
            await audioSession.deactivate()
        } catch {
            Log.playback.error("SMB playback start failed (unmapped): \(error.networkDiagnostic)")
            phase = .failed(.unexpected("playback start failed", underlying: AnySendableError(error)))
            await tearDownSMBBridge()
            await audioSession.deactivate()
        }
    }

    /// Invokes + clears the SMB bridge cleanup exactly once. Nil'ing before the await makes it
    /// idempotent against the racing `stop()`/`tearDownEngine()` sites; a no-op on Jellyfin and
    /// VLC-route sessions (`smbCleanup` is nil).
    private func tearDownSMBBridge() async {
        if let cleanup = smbCleanup {
            smbCleanup = nil
            await cleanup()
        }
    }

    /// Persists the current SMB position at most every ~10s — the local mirror of the
    /// Jellyfin progress-report cadence, shared by the `.playing` and `.paused` beat arms.
    /// The duration only rides along when it's both real (`hasKnownDuration`) AND TRUSTED
    /// (`session.hasTrustworthyDuration`): an incomplete file can play with a NUMERIC but
    /// ESTIMATED length (VLCKitEngine's fileSize×time/readBytes guess), and the store's
    /// 95%-finished rule must never clear real progress against that guess. Fire-and-forget
    /// into the store actor so a beat never blocks on UserDefaults.
    private func saveSMBResumeThrottled() {
        guard let session = smbSession else { return }
        guard Date.now.timeIntervalSince(session.lastResumeWrite) >= 10 else { return }
        smbSession?.lastResumeWrite = .now
        let position = currentPosition
        let duration = (hasKnownDuration && session.hasTrustworthyDuration) ? currentDuration : nil
        let itemID = session.itemID
        session.resumeSaveTask?.cancel()
        smbSession?.resumeSaveTask = Task {
            await smbResumeStore.save(position: position, duration: duration, for: itemID)
        }
    }

    /// The single teardown path for the SMB resume session: nils the whole value — dropping
    /// the id, the trust bit, and the throttle clock together — BEFORE awaiting the in-flight
    /// save, so a concurrent throttled beat can't spawn a new save during the await and the
    /// terminal write that follows at the call site (`stop()` saves, `.ended` clears) can't be
    /// outrun by a stale one. Idempotent: a nil session is a no-op. The caller captures the id
    /// it needs FIRST, since this clears it. (The SMB bridge cleanup is separate — see
    /// `tearDownSMBBridge`; it's torn down after engine teardown, not with the session.)
    private func clearSMBSession() async {
        guard let session = smbSession else { return }
        smbSession = nil
        await session.resumeSaveTask?.value
    }

    /// Resolve + load + play. Shared by first play (`start`) and a transcode
    /// track switch (`switchTranscodeTrack`). On the transcode path the menus
    /// are sourced from the server's full track list, since the HLS manifest
    /// only carries the single chosen rendition.
    private func beginPlayback(
        item: ItemDetail,
        startTime: CMTime?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
        reusingEngine: Bool = false
    ) async throws {
        try checkStillActive()
        // Kicked off alongside the profile build + network resolve: the first
        // resolution materializes font files off-main (see SubtitleFontLocator),
        // so it overlaps the long network call instead of stalling makeAsset.
        async let subtitleFonts = SubtitleFontLocator.resolved()
        let caps = await deviceProfileBuilder.build()
        let resolved = try await resolve(item.id, caps, startTime, audioStreamIndex, subtitleStreamIndex)
        // The critical fence: resolve is the long network call, so this is where an
        // exit-during-loading usually lands. Bail BEFORE building an engine.
        try checkStillActive()
        self.resolved = resolved
        subtitleURLs = resolved.subtitleStreamURLs   // Jellyfin: index → authed VTT URL
        startKeepalive(for: resolved)
        currentAudioStreamIndex = audioStreamIndex ?? resolved.defaultAudioStreamIndex
        // Carries the user's choice across audio switches (none stays none, a
        // chosen sub stays chosen). On FIRST play the preference application
        // below/at-.ready may seed it from the server default — text subs only,
        // so nothing is ever auto-burned-in (image subs never reach the menus).
        currentSubtitleStreamIndex = subtitleStreamIndex
        if resolved.method == .transcode {
            populateTranscodeMenus(from: resolved)
            // First play only (a track switch carries the user's own choice):
            // surface the subtitle Jellyfin computed from the user's language +
            // mode preferences. The audio default is already honored above via
            // `resolved.defaultAudioStreamIndex` — the server bakes it in.
            if !didApplyPreferredTracks {
                didApplyPreferredTracks = true
                await applyTranscodeDefaultSubtitle(from: resolved)
            }
        } else {
            // Direct-play: embedded tracks only arrive with the engine's .ready, but
            // external sidecar subs are already known here — surface them so the
            // subtitles chip works while the stream buffers. .ready replaces this
            // with the full engine inventory + the same external append.
            availableSubtitleTracks = Self.externalSubtitleTracks(from: resolved)
        }
        recomputeMediaSummary()

        let asset = Self.makeAsset(from: resolved, subtitleFonts: await subtitleFonts)
        try await loadAndPlay(asset, reusingEngine: reusingEngine)
    }

    /// Select the engine for `asset`, (re)build or reuse it, load, fence, and play —
    /// the shared tail of every play path. `beginPlayback` (Jellyfin) and
    /// `start(smbItem:)` (SMB) both end here, so the engine lifecycle (subscription,
    /// Now Playing wiring, tvOS display-mode match, load-failure teardown, rate
    /// re-apply) lives in exactly one place.
    private func loadAndPlay(_ asset: PlayableAsset, reusingEngine: Bool) async throws {
        let id = EngineSelector.select(hints: asset.hints)

        // Reuse the live engine when a transcode track switch keeps the same engine
        // type: reloading the asset on the existing AVPlayer keeps its video layer
        // mounted, so the surface holds the last frame through the swap instead of
        // tearing down to black. A fresh play (or an engine-type change) builds a new
        // engine and wires up its state subscription + Now Playing handlers.
        let engine: any PlaybackEngine
        if reusingEngine, let existing = self.engine, existing.id == id {
            engine = existing
        } else {
            engine = engineFactory(id)
            self.engine = engine
            subscribe(to: engine)
            nowPlaying.configure(
                onSeek: { [weak self] time in Task { await self?.seek(to: time) } },
                // Route through setPlaying (not engine.play/pause directly) so a remote command
                // clears any pending scrub latch — otherwise it's swallowed and the glyph sticks.
                onPlay: { [weak self] in self?.setPlaying(true) },
                onPause: { [weak self] in self?.setPlaying(false) }
            )
        }

        do {
            try await engine.load(asset)
            // Last fence before audio starts: an exit that landed during load must
            // not be answered with play() on a player that's already dismissed.
            try checkStillActive()
            #if os(tvOS)
            // Between load and play, never later: ask the TV to match the
            // content's native mode (HDR / frame rate) and wait for the switch
            // to settle behind the loading scrim. Applying this after frames
            // render blanks/re-handshakes HDMI mid-decode and wedged the video
            // pipeline on device (black/frozen video with live audio).
            //
            // Fresh content only: a track switch re-delivers the SAME video
            // (new session, identical format), so the display is already
            // matched and prepare() would just burn its full arm window in
            // dead waiting before every audio switch.
            if !reusingEngine {
                await DisplayCriteriaMatcher.prepare(for: engine)
                try checkStillActive()
            }
            #endif
        } catch {
            // A load failure (or an exit mid-load) must not leave the engine + its
            // state subscription dangling: tear down before propagating, so
            // start()/switchTranscodeTrack surface .failed with no leaked Task and
            // no open AsyncStream. (Idempotent vs a stop() that already tore down.)
            await tearDownEngine()
            throw error
        }
        // Startup-metric anchor: recorded at dispatch, consumed by this session's
        // first `.playing` beat in `handle(_:)` — see `startupMillis`.
        startupClockStart = ContinuousClock.now
        await engine.play()
        // A freshly-built engine starts at 1.0×; re-apply the chosen speed so it
        // survives an engine rebuild (track switch / first play after a speed change).
        if playbackRate != 1 {
            await engine.setRate(playbackRate)
        }
    }

    /// Cancels the engine's state subscription and tears the engine down, clearing
    /// the reference. The focused teardown (no session report, no UI reset) used by
    /// a load failure and a failed track switch. The session's keepalive and
    /// encoding die here too: with no engine left to consume the stream, pinging
    /// the session would keep an orphaned ffmpeg job transcoding flat-out for as
    /// long as the user sits on the failure overlay — the exact contention
    /// `stopEncoding` exists to prevent. Both are idempotent vs a racing `stop()`.
    private func tearDownEngine() async {
        stateTask?.cancel()
        stateTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil
        if let engine {
            await engine.teardown()
            self.engine = nil
        }
        // A load failure tears the bridge down with the engine: nothing consumes the stream, so
        // the orphaned listener + its SMB connection must not outlive the failed load.
        await tearDownSMBBridge()
        await stopEncodingIfNeeded()
    }

    /// Synchronously fences the exit before the async `stop()` gets a MainActor
    /// turn: the dismiss trigger calls this first, so an in-flight `start()` that
    /// resumes in between can't slip past a checkpoint and build/play an engine
    /// for a player that's already going away.
    func beginExit() { isExiting = true }

    /// Bails the start path when the player is exiting (`beginExit()`/`stop()`) or
    /// the hosting `.task` was cancelled (the view disappeared mid-load). Checked
    /// after every await between "play tapped" and "engine playing" so a slow
    /// resolve can never start audio after the player is gone.
    private func checkStillActive() throws {
        if isExiting { throw CancellationError() }
        try Task.checkCancellation()
    }

    func stop() async {
        isExiting = true
        guard !didStop else { return }
        didStop = true
        // Final local-resume write for SMB sessions — no throttle, and BEFORE teardown
        // zeroes currentPosition. The store's own rules turn a <5s or ≥95%-of-known-
        // duration position into a clear. Skipped at exactly zero: a session that never
        // produced a beat (failed load, exit during resolve) must not wipe the stored
        // resume it was about to honor — the Jellyfin analog of reportStoppedIfNeeded's
        // didReportStart gate. Nil after: the session is over.
        if let session = smbSession {
            // Capture before clearing — the terminal write below needs the id + trust bit.
            let itemID = session.itemID
            let trusted = session.hasTrustworthyDuration
            // Clears the session (id + trust + throttle clock) and awaits a stale throttled
            // save so it can't outrun this terminal write.
            await clearSMBSession()
            if CMTimeGetSeconds(currentPosition) > 0 {
                await smbResumeStore.save(
                    position: currentPosition,
                    duration: (hasKnownDuration && trusted) ? currentDuration : nil,
                    for: itemID
                )
            }
        }
        stateTask?.cancel()
        stateTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        transportTask?.cancel()
        transportTask = nil
        if let engine {
            await engine.teardown()
        }
        // Kill the SMB bridge with the session: an orphaned listener holds an SMB connection and
        // a LAN-reachable file URL. No-op on Jellyfin/VLC-route sessions (smbCleanup is nil).
        await tearDownSMBBridge()
        nowPlaying.clear()
        // Exit kills the encoding explicitly (not just via the stop report):
        // a session that wedged before its first .playing beat never reports
        // start/stop, and its orphaned job would contend with the next play.
        await stopEncodingIfNeeded()
        await reportStoppedIfNeeded()
        await audioSession.deactivate()
        engine = nil
        playingItem = nil
        pendingItemID = nil
        smbResolve = nil
        currentAudioStreamIndex = nil
        currentSubtitleStreamIndex = nil
        // A re-anchor in flight is abandoned by reloadTranscode's exit fence; clear its
        // state too so a retry()/replay can't inherit a stale target or a stuck flag.
        pendingReanchorTarget = nil
        isReanchoring = false
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil
        availableAudioTracks = []
        availableSubtitleTracks = []
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        trackSwitchFailure = nil
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        activeSubtitleCues = []
        subtitleURLs = [:]
        smbExternalSubtitleTracks = []
        clientSubtitleDelayMs = 0
        currentPosition = .zero
        currentDuration = .zero
        chapterFractions = []
        bufferedTo = nil
        segmentsTask?.cancel()
        segmentsTask = nil
        segments = []
        adjacentEpisodes = .none
        clearStall()
        isPlaying = false
        scrubResumeIntent = nil
        mediaSummary = nil
        // NOTE: playbackRate is deliberately NOT reset here. retry() routes through
        // stop()→start(); zeroing it would silently drop the user's chosen speed on
        // the fresh engine (beginPlayback's re-apply guard would see 1.0×). A real
        // dismiss discards the whole view model, so the next item starts at the
        // init default (1.0×) anyway.
    }

    /// Sends the final PlaybackStopped beat for the current session exactly once.
    /// Shared by `stop()`, a natural `.ended`, and a transcode track switch (which
    /// closes the outgoing session before opening the next).
    ///
    /// Requires `didReportStart`: a session that never reported start must never
    /// report stop. Without this guard a re-resolve that *fails* (so the flags were
    /// reset but `self.resolved` was never advanced past the old/failed session)
    /// would let `stop()` fire a second/orphan PlaybackStopped.
    private func reportStoppedIfNeeded() async {
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
    private func startKeepalive(for resolved: ResolvedPlayback) {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        guard resolved.method == .transcode else { return }
        let sessionID = resolved.playSessionID
        let interval = keepaliveInterval
        keepaliveTask = Task { [playbackInfo] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await playbackInfo.pingSession(playSessionID: sessionID)
            }
        }
    }

    /// Arms the one-shot copy-vs-reencode delivery probe for the just-started
    /// transcode session. ffmpeg spins up lazily and only populates the session's
    /// `TranscodingInfo` once it's encoding, so the probe walks `deliveryProbeSchedule`
    /// (≈2s then +5s in production) waiting then fetching at each step; a nil result
    /// (session/`TranscodingInfo` not up yet) moves to the next entry, and running out
    /// of the schedule gives up silently — the seek gate stays conservative on a nil
    /// delivery anyway. Direct play has no job to probe. Clears any stale delivery up
    /// front so the window (and a re-probe after a track switch, where burn-in can flip
    /// the answer) reads "probing…" until the fresh result lands.
    private func startDeliveryProbe(for resolved: ResolvedPlayback) {
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil
        deliveryProbeExhausted = false
        guard resolved.method == .transcode else { return }
        let sessionID = resolved.playSessionID
        let fetch = fetchDelivery
        let schedule = deliveryProbeSchedule
        deliveryProbeTask = Task { [weak self] in
            for delay in schedule {
                do { try await Task.sleep(for: delay) } catch { return }
                if Task.isCancelled { return }
                if let delivery = await fetch(sessionID) {
                    if Task.isCancelled { return }
                    self?.transcodeDelivery = delivery
                    return
                }
            }
            if !Task.isCancelled { self?.deliveryProbeExhausted = true }
        }
    }

    /// Kills the outgoing session's server-side transcode job, exactly once.
    /// MUST run before resolving a replacement stream: with throttling off, an
    /// abandoned 4K job keeps transcoding flat-out and starves the new job's
    /// segment production past AVPlayer's 3s timeout — every post-switch
    /// segment then dies with -12889 in an unrecoverable buffering livelock
    /// (device-diagnosed 2026-06-11). jellyfin-web fires the same call before
    /// every in-place stream change. Direct play has no job — skip.
    private func stopEncodingIfNeeded() async {
        guard let resolved, resolved.method == .transcode, !didStopEncoding else { return }
        didStopEncoding = true
        await playbackInfo.stopEncoding(playSessionID: resolved.playSessionID)
    }

    func retry() async {
        let item = playingItem
        let id = pendingItemID
        let smb = smbResolve
        await resetForReplay()
        if let smb { await start(resolvingSMB: smb) }
        else if let item { await start(item: item) }
        else if let id { await start(itemID: id) }
        else { Log.playback.error("retry() had no item or id to replay") }
    }

    /// Tears the current session down (reporting its stop, killing its encode job)
    /// and clears the per-session fences so a fresh `start` can run on this same
    /// view model. Shared by `retry()` (same item) and `replacePlayback` (episode
    /// swap). `stop()` arms the exit fence; this is a restart, not an exit, so the
    /// fence is disarmed for the fresh start path.
    private func resetForReplay() async {
        await stop()
        isExiting = false
        didStop = false
        phase = .idle
        didReportStart = false
        didReportStopped = false
        didStopEncoding = false
        lastPosition = .zero
        startupClockStart = nil
        startupMillis = nil
    }

    func selectAudioTrack(_ track: AudioTrack) async {
        // Dropped (not queued) while a start or a prior switch is mid-flight: the
        // selected label is set before the re-resolve below, so accepting a pick
        // here would show a track the reload never honors.
        guard !isStartingPlayback, !isSwitchingTracks else { return }
        // Re-picking the playing track is a no-op: on transcode it would be a
        // full re-resolve + reload hitch, on direct-play a pointless preference
        // round-trip. (A failed switch restores `selectedAudioTrack` to the
        // fallback first, so the scrim's retry still passes this guard.)
        guard track != selectedAudioTrack else { return }
        // Direct-play has every track in the stream → switch in-engine (instant).
        // Transcode carries only the baked-in rendition → re-resolve around the
        // chosen source index (track.id) and reload at the current position.
        if resolved?.method == .transcode {
            // Transcode menus carry `.jellyfinStream` ids — the source stream index
            // the server selects by. A non-jellyfin id here would be a wiring bug.
            guard let index = track.id.jellyfinStreamIndex else { return }
            let previous = selectedAudioTrack
            selectedAudioTrack = track
            trackSwitchFailure = nil
            switch await switchTranscodeTrack(audioStreamIndex: index, subtitleStreamIndex: currentSubtitleStreamIndex) {
            case .completed:
                persistTrackSelection(.audio(languageCode: track.languageCode))
            case .abandoned:
                // The reload never ran (re-entrant pick or exit) — quietly restore
                // the checkmark so the menu doesn't show a track that isn't playing.
                selectedAudioTrack = previous
            case .fellBack(let error):
                // Playback resumed on the previous track: restore the checkmark and
                // surface the failure scrim (retry / keep current track).
                selectedAudioTrack = previous
                trackSwitchFailure = TrackSwitchFailure(
                    requested: .audio(track),
                    fallback: previous.map(TrackPick.audio),
                    error: error
                )
            case .failed:
                break   // phase == .failed — the general error scrim owns the surface
            }
        } else {
            guard let engine else { return }
            await engine.setAudioTrack(track)
            selectedAudioTrack = track
            persistTrackSelection(.audio(languageCode: track.languageCode))
        }
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) async {
        // Same drop-don't-queue rule as selectAudioTrack: mid-switch, `resolved`
        // still points at the outgoing session, so a sidecar fetch would read the
        // old session's subtitle URLs.
        guard !isStartingPlayback, !isSwitchingTracks else { return }
        // A burned-in (image) subtitle has no sidecar to fetch — the server can only
        // deliver it baked into the video, which costs a full re-encode. Route through
        // the same re-resolve `selectAudioTrack` uses instead of the sidecar-fetch
        // path below; the picked index lands as `subtitleStreamIndex` on the next
        // PlaybackInfo POST and the server burns it in from there.
        if let track, track.isBurnedIn {
            // Re-picking the already-burned-in track is a no-op — it would cost a
            // pointless re-resolve/reload for a stream already playing. (A failed
            // switch restores `selectedSubtitleTrack` to the fallback first, so the
            // scrim's retry still passes this guard.)
            guard track != selectedSubtitleTrack else { return }
            guard let index = track.id.jellyfinStreamIndex else { return }
            await reloadSubtitleTranscode(to: track, subtitleStreamIndex: index)
            return
        }
        // Leaving an ACTIVE burn-in for anything else — Off or a text sub — needs the
        // same re-resolve a pick INTO a burn-in gets above: the server is still
        // re-encoding the old image into the video until a fresh transcode says
        // otherwise. Without this, "Off" doesn't turn it off, and a text pick just
        // draws its overlay on top of the still-burned-in image (double-stacked).
        // Picking one burn-in into another already reloads unconditionally above, so
        // this only matters for the two branches below.
        let leavingBurnIn = resolved?.method == .transcode && selectedSubtitleTrack?.isBurnedIn == true
        // A `.jellyfinStream` id is an external/sidecar text sub we render ourselves
        // (transcode: every text sub; direct-play: the external ones) — fetch + draw it
        // via SubtitleOverlayView with the engine's own subtitle held off. An embedded
        // direct-play track carries a `.vlc`/`.avKitOption` id the engine renders; `nil`
        // is Off.
        if let track, let index = track.id.jellyfinStreamIndex {
            if leavingBurnIn {
                // Sidecar activation must wait for the reload to land — fetching now would
                // read the still-burning-in outgoing session's (stale) subtitleURLs.
                await reloadSubtitleTranscode(to: track, subtitleStreamIndex: index) {
                    await self.activateSidecarSubtitle(track, index: index)
                }
                return
            }
            await activateSidecarSubtitle(track, index: index)
        } else if resolved?.method == .transcode {
            if leavingBurnIn {
                await reloadSubtitleTranscode(to: nil, subtitleStreamIndex: -1)
                return
            }
            // Transcode Off, no active burn-in: no engine subtitle exists (subs never
            // ride the manifest) and the server isn't burning anything in, so just drop
            // the overlay and record Jellyfin's "no subtitle" sentinel — no reload earned.
            selectedSubtitleTrack = nil
            currentSubtitleStreamIndex = -1
            clearSidecarSubtitle()
        } else {
            // Direct-play EMBEDDED track (or Off): the engine renders it. Clear any
            // client-side sidecar that a prior external selection left up.
            guard let engine else { return }
            await engine.setSubtitleTrack(track)
            clearSidecarSubtitle()
            selectedSubtitleTrack = track
        }
        persistTrackSelection(.subtitles(languageCode: track?.languageCode))
    }

    /// Re-resolves the transcode around a new subtitle target and reports the outcome
    /// through the same optimistic-set/restore/scrim machinery `selectSubtitleTrack`'s
    /// burn-in branch always used — now shared with the two "leaving an active burn-in"
    /// branches (Off, a text sub) that used to skip the reload entirely. `onCompleted`
    /// runs once the reload lands, for target-specific follow-up that must not race the
    /// still-burning-in outgoing session (a text sub's sidecar fetch).
    private func reloadSubtitleTranscode(
        to target: SubtitleTrack?,
        subtitleStreamIndex: Int,
        onCompleted: () async -> Void = {}
    ) async {
        let previous = selectedSubtitleTrack
        selectedSubtitleTrack = target
        trackSwitchFailure = nil
        // No overlay renders while the reload is in flight — drop whatever sidecar was
        // showing (a burn-in target shows nothing either way; the failure/abandon arms
        // below re-arm it via restoreSidecarSubtitle if the previous track had one).
        clearSidecarSubtitle()
        switch await switchTranscodeTrack(audioStreamIndex: currentAudioStreamIndex, subtitleStreamIndex: subtitleStreamIndex) {
        case .completed:
            await onCompleted()
            persistTrackSelection(.subtitles(languageCode: target?.languageCode))
        case .abandoned:
            selectedSubtitleTrack = previous
            restoreSidecarSubtitle(previous)
        case .fellBack(let error):
            selectedSubtitleTrack = previous
            restoreSidecarSubtitle(previous)
            trackSwitchFailure = TrackSwitchFailure(
                requested: .subtitle(target),
                fallback: previous.map(TrackPick.subtitle),
                error: error
            )
        case .failed:
            break   // phase == .failed — the general error scrim owns the surface
        }
    }

    /// Activate a client-rendered sidecar subtitle: the app draws it via
    /// `SubtitleOverlayView`, so the ENGINE must not also render one. Deselecting the
    /// engine subtitle is mandatory on EVERY external pick — VLC auto-selects an embedded
    /// default and keeps discovering text tracks as the demux runs, so a stray embedded
    /// sub would otherwise render THROUGH the overlay. The server-preferred initial pick
    /// used to skip this deselect — that was the double-subtitle bug. Harmless no-op on
    /// the transcode/AVKit path, which has no in-manifest text track to deselect.
    private func activateSidecarSubtitle(_ track: SubtitleTrack, index: Int) async {
        await engine?.setSubtitleTrack(nil)
        currentSubtitleStreamIndex = index
        selectedSubtitleTrack = track
        loadSidecarSubtitle(streamIndex: index)
    }

    /// Re-arms the client overlay for the track a failed/abandoned subtitle switch fell
    /// back to — every `reloadSubtitleTranscode` failure/abandon arm (a pick INTO a
    /// burn-in, or leaving one for Off/a text sub) clears the sidecar optimistically
    /// before the re-resolve; when that re-resolve doesn't land, the still-mounted
    /// previous session needs its text overlay back (a bare Off/burn-in track needs
    /// nothing — there's no sidecar to fetch either way).
    private func restoreSidecarSubtitle(_ track: SubtitleTrack?) {
        guard let track, let index = track.id.jellyfinStreamIndex, !track.isBurnedIn else { return }
        loadSidecarSubtitle(streamIndex: index)
    }

    /// Fire-and-forget preference write-back: the service gates on the user's
    /// Remember-Selections flags and swallows failures, so this can ride every
    /// successful pick without touching playback.
    private func persistTrackSelection(_ update: TrackSelectionUpdate) {
        let remember = rememberTrackSelection
        Task { await remember(update) }
    }

    // MARK: - Server language preferences (initial tracks)

    /// Jellyfin folds the user's language preferences (audio/subtitle language,
    /// subtitle mode, PlayDefaultAudioTrack) into PlaybackInfo's default stream
    /// indices — the server is the single implementation of that logic. On the
    /// transcode path the audio default is baked into the stream; the subtitle
    /// default is surfaced here as the initial sidecar selection. Text subs only:
    /// burn-in is opt-in, so a PGS/VobSub default (however the server picked it)
    /// is never auto-applied — that would silently force a re-encode (and
    /// possibly HDR→SDR) on first play with no user action. The user can still
    /// pick it explicitly from the menu.
    private func applyTranscodeDefaultSubtitle(from resolved: ResolvedPlayback) async {
        guard let index = resolved.defaultSubtitleStreamIndex,
              let track = availableSubtitleTracks.first(where: { $0.id == .jellyfinStream(index) && !$0.isBurnedIn })
        else { return }
        await activateSidecarSubtitle(track, index: index)
    }

    /// Direct-play analog of `applyTranscodeDefaultSubtitle`: the whole file is
    /// delivered, so the ENGINE picks initial tracks by its own rules (AVKit:
    /// system language + accessibility) and the server's preference-derived
    /// defaults never apply on their own. Re-point the engine when the user's
    /// Jellyfin preference disagrees; when no track matches the preferred
    /// language, leave the engine's pick — the graceful fallback.
    private func applyServerPreferredTracks() async {
        guard let resolved, let engine else { return }

        // AUDIO — match the default stream's language against the inventory.
        if let index = resolved.defaultAudioStreamIndex,
           let preferred = resolved.mediaStreams.first(where: { $0.kind == .audio && $0.index == index }),
           let language = preferred.language,
           !TrackLanguage.matches(selectedAudioTrack?.languageCode, language),
           let match = availableAudioTracks.first(where: { TrackLanguage.matches($0.languageCode, language) }) {
            await engine.setAudioTrack(match)
            selectedAudioTrack = match
        }

        // SUBTITLES — only when the server's mode+language logic says one should show.
        guard let index = resolved.defaultSubtitleStreamIndex,
              let preferred = resolved.mediaStreams.first(where: { $0.kind == .subtitle && $0.index == index })
        else { return }
        if let external = availableSubtitleTracks.first(where: { $0.id == .jellyfinStream(index) }) {
            // An external sidecar default is an EXPLICIT server preference, so it overrides the
            // engine's own auto-pick. VLC selects a default/forced embedded sub on its own, and the
            // `.ready` inventory seed above adopts it into `selectedSubtitleTrack`; gating this
            // branch on `selectedSubtitleTrack == nil` (as it used to) let that embedded pick win
            // the race and strand the external default while the embedded one rendered THROUGH the
            // overlay (the double-subtitle bug). `activateSidecarSubtitle` holds the engine subtitle
            // off (`setSubtitleTrack(nil)`) so only the client-drawn sidecar shows.
            await activateSidecarSubtitle(external, index: index)
        } else if selectedSubtitleTrack == nil, let match = availableSubtitleTracks.first(where: {
            !$0.isExternal
                && TrackLanguage.matches($0.languageCode, preferred.language)
                && $0.isForced == preferred.isForced
        }) {
            // An EMBEDDED-language match applies only when the engine didn't already auto-select a
            // subtitle (AVKit honors the system's accessibility caption setting; never fight that).
            await engine.setSubtitleTrack(match)
            selectedSubtitleTrack = match
        }
    }

    /// Fetches + parses the sidecar WebVTT for `streamIndex` into
    /// `activeSubtitleCues`. Cancels any in-flight fetch first so a slow/stale
    /// parse can't land on screen after a newer pick.
    private func loadSidecarSubtitle(streamIndex: Int) {
        subtitleFetchTask?.cancel()
        clientSubtitleDelayMs = 0   // a fresh sidecar starts un-nudged
        guard let url = subtitleURLs[streamIndex] else {
            activeSubtitleCues = []
            return
        }
        let fetch = subtitleFetch
        // Parser by extension: Jellyfin's sidecar endpoint serves WebVTT, but an SMB sibling
        // is whatever the release shipped — `.srt` is the common one and WebVTTParser can't
        // read its `HH:MM:SS,mmm` comma timing. `.ass`/`.ssa` have no client renderer yet, so
        // they fall through to WebVTT (yields []) rather than mis-parsing.
        let isSRT = url.pathExtension.lowercased() == "srt"
        subtitleFetchTask = Task { [weak self] in
            guard let data = await fetch(url) else { return }
            let cues = isSRT ? SRTParser.parse(data: data) : WebVTTParser.parse(data: data)
            if Task.isCancelled { return }
            self?.activeSubtitleCues = cues
        }
    }

    private func clearSidecarSubtitle() {
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        activeSubtitleCues = []
        clientSubtitleDelayMs = 0
    }

    /// How a transcode track switch ended — drives `selectAudioTrack`'s selection
    /// restore and the failure scrim.
    private enum TrackSwitchOutcome {
        case completed
        /// The reload was dropped or cancelled (re-entrant pick / player exit) —
        /// nothing changed; restore the menu selection quietly.
        case abandoned
        /// The re-resolve failed while the outgoing stream was still mounted:
        /// playback resumed on the previous track (the silent fallback).
        case fellBack(AppError)
        /// The engine was lost mid-reload — phase is `.failed`, the general error
        /// scrim owns the surface.
        case failed
    }

    /// The one seek entry point for every source: scrub, chapter jump, segment skip,
    /// and the Now Playing remote. An OUT-OF-BUFFER seek on a RE-ENCODE transcode
    /// re-resolves a fresh transcode at the target instead of seeking in-stream —
    /// Jellyfin RE-ENCODES fMP4 with `-noaccurate_seek`, so an in-playlist seek restarts
    /// ffmpeg mid-session and the new segments' video clock drifts from the player clock,
    /// desyncing the client subtitle overlay (jellyfin#15845). A fresh session's
    /// resume-seek lands frame-accurate (that's why "dismiss + restart fixes it").
    ///
    /// A REMUX transcode (video stream-copy, `transcodeDelivery.isVideoDirect == true`)
    /// is exempt: the server seeks those on the `isHlsRemuxing` keyframe branch
    /// (EncodingHelper.cs), which is frame-accurate — `-noaccurate_seek` is a
    /// RE-ENCODE-only failure mode — so a remux seeks in-stream like direct play, with
    /// no re-buffer. In-buffer transcode seeks, and every direct-play / VLC / SMB seek,
    /// stay in-stream too. A nil/unknown delivery (still probing) stays conservative and
    /// re-anchors. Cost: the re-anchor re-buffers, but an out-of-buffer re-encode seek
    /// already re-buffers today (the engine fetches the segment), so this swaps a
    /// drifting in-place restart for an aligned fresh one.
    /// Returns `true` when the seek RE-ANCHORED (rebuilt the transcode via
    /// `reloadTranscode`, which force-resumes playback), `false` for an in-stream
    /// `engine.seek`. `commitScrubSeek` branches on it to restore a paused scrub's
    /// pause after a force-resuming reload.
    @discardableResult
    func seek(to target: CMTime) async -> Bool {
        guard let engine else { return false }
        // Only an out-of-buffer RE-ENCODE transcode drifts. A remux (proven video copy)
        // seeks on the server's accurate keyframe branch, and everything else (direct
        // play / VLC / SMB) seeks in-stream — as does a nil delivery once we know it's
        // not a re-encode. Conservative while the probe is still nil: re-anchor.
        guard resolved?.method == .transcode, transcodeDelivery?.isVideoDirect != true else {
            await engine.seek(to: target)
            return false
        }
        // A re-anchor already in flight makes the engine's buffer state meaningless
        // (it's mid-reload) — hand the newest target to the drain and let it win.
        if isReanchoring {
            pendingReanchorTarget = target
            return true
        }
        if await engine.isBuffered(at: target) {
            await engine.seek(to: target)
            return false
        } else {
            pendingReanchorTarget = target
            await drainReanchorSeeks()
            return true
        }
    }

    /// A scrub-commit seek: the gated `seek(to:)` followed by the pre-scrub transport
    /// replay. Every touch/VoiceOver/tvOS scrub commit routes its seek through `seek(to:)`
    /// so an out-of-buffer RE-ENCODE transcode re-anchors (jellyfin#15845) instead of
    /// drifting the subtitle overlay; the touch drag additionally pauses the engine to
    /// hold the still frame, so it must replay the user's pre-scrub play state here.
    ///
    /// The wrinkle a bare `seek` can't cover: a re-anchor runs `reloadTranscode`, whose
    /// `loadAndPlay` UNCONDITIONALLY resumes — so a scrub that began while PAUSED comes
    /// back playing unless we re-pause it. An in-stream seek leaves the drag's pause in
    /// place, so it only needs the resume. `resume` is the chain-start play state
    /// (`scrubWasPlaying`); the caller owns the scrub latch (`beginScrubLatch` /
    /// `endScrubLatch`) and the generation-guarded `isScrubbing` release around this call.
    func commitScrubSeek(to target: CMTime, resume: Bool) async {
        let didReanchor = await seek(to: target)
        guard let engine else { return }
        if resume {
            // The reload already resumed; only the in-stream seek left the drag-pause on.
            if !didReanchor { await engine.play() }
        } else if didReanchor {
            // The reload force-resumed against the user's pause — restore it.
            await engine.pause()
        }
    }

    /// Single-flight drain of `pendingReanchorTarget`: the first caller re-resolves the
    /// transcode at the latest pending target, then loops to pick up any newer target
    /// that arrived during the (multi-second) re-buffer — so a scrub past the buffer
    /// settles on where the user stopped, not the first overshoot.
    private func drainReanchorSeeks() async {
        guard !isReanchoring else { return }
        isReanchoring = true
        defer { isReanchoring = false }
        while let target = pendingReanchorTarget {
            pendingReanchorTarget = nil
            // Newest-wins: a seek arriving during the reload re-sets the target and the
            // loop picks it up next iteration. But STOP on any non-`.completed` outcome —
            // `.abandoned` (a concurrent track switch holds the reload, or the player is
            // exiting) would otherwise spin against the block, and `.failed`/`.fellBack`
            // would reload into a torn-down or fallback surface. The rare dropped seek
            // (scrub during an audio switch) is re-issued by the next scrub.
            guard case .completed = await reloadTranscode(
                resumeAt: target,
                audioStreamIndex: currentAudioStreamIndex,
                subtitleStreamIndex: currentSubtitleStreamIndex
            ) else { break }
        }
    }

    /// Re-resolve a fresh transcode session resuming at `resume`, reusing the engine so
    /// its video layer + audio session stay live (the surface holds the last frame
    /// through the swap instead of blinking to black). Shared by the audio/subtitle
    /// track switch (new indices, resume at the current position) and the re-anchor seek
    /// (same indices, `resume` = the seek target). Costs a brief re-buffer — the server
    /// re-encodes around the new anchor.
    private func reloadTranscode(
        resumeAt resume: CMTime,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async -> TrackSwitchOutcome {
        // The chips stay mounted through .loading — a second pick (or seek) mid-reload
        // must wait for (not race) the in-flight reload.
        guard !isSwitchingTracks, let item = playingItem else { return .abandoned }

        // Keep the engine + its layer alive across the reload (beginPlayback reloads
        // it). Suppress the outgoing stream's trailing beats while we do.
        isSwitchingTracks = true
        defer { isSwitchingTracks = false }

        // Freeze the current frame at the moment of the swap — the frosted cover
        // frosts over it while the new transcode buffers, and pausing stops the
        // outgoing audio instead of letting it play on under the cover.
        await engine?.pause()
        phase = .loading
        // The outgoing stream's buffer is meaningless for the new transcode —
        // showing it would advertise instant seeks the reload can't honor.
        bufferedTo = nil
        // Kill the outgoing encoding FIRST (the replacement job must not fight
        // an abandoned one for the source file), close the outgoing session,
        // then reset the lifecycle flags — the reload is a brand-new play
        // session that must reportStart/reportStopped/stopEncoding on its own
        // terms. Trade-off: if the re-resolve FAILS, the silent fallback
        // resumes the old stream on a dead encoding — it plays out its buffer
        // and may stall into the failure scrim, which is still strictly better
        // than every successful reload livelocking.
        await stopEncodingIfNeeded()
        await reportStoppedIfNeeded()
        didReportStart = false
        didReportStopped = false
        didStopEncoding = false
        // The reload dispatches a fresh engine.play() below (via beginPlayback →
        // loadAndPlay), which re-arms startupClockStart — this session's old metric
        // must not linger on screen until that beat lands.
        startupClockStart = nil
        startupMillis = nil
        // The delivery verdict belonged to the outgoing session. A burn-in subtitle
        // switch can flip the video to a re-encode (isVideoDirect false), and a
        // re-anchor opens a fresh session, so drop the stale verdict now — the seek
        // gate goes conservative (re-anchor) until the new session's first `.playing`
        // beat re-probes.
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil

        do {
            try await beginPlayback(
                item: item,
                startTime: resume,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                reusingEngine: true
            )
            return .completed
        } catch is CancellationError {
            // Exit raced the reload — stop() already owns the teardown.
            return .abandoned
        } catch let error as AppError {
            return await fallBackAfterFailedSwitch(error)
        } catch {
            Log.playback.error("transcode reload failed: \(error.networkDiagnostic)")
            return await fallBackAfterFailedSwitch(
                .unexpected("transcode reload failed", underlying: AnySendableError(error))
            )
        }
    }

    /// Rebuilds the transcode around new stream indices, resuming at the current
    /// position. Costs a brief re-buffer — the server has to re-encode around the
    /// chosen track. The engine instance is REUSED (reloaded), so the video surface
    /// stays mounted and holds the last frame through the swap instead of blinking to
    /// black; the audio session stays active too.
    private func switchTranscodeTrack(audioStreamIndex: Int?, subtitleStreamIndex: Int?) async -> TrackSwitchOutcome {
        // The transcode plays a full-timeline HLS playlist the engine SEEKS to the
        // resume offset (Jellyfin ignores StartTimeTicks for the playlist start), so
        // currentPosition is already absolute media time — resume the new stream right
        // there. (Adding the old origin double-counted it, so resume drifted further
        // forward on every track switch.)
        await reloadTranscode(
            resumeAt: currentPosition,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex
        )
    }

    /// The design's "failures are loud, fallbacks are silent": when the re-resolve
    /// failed BEFORE the reused engine reloaded, the previous stream is still
    /// mounted — just paused — so resume it instead of killing playback, and let
    /// the failure scrim offer a retry. The reporting flags were reset for the new
    /// session that never started, so the resumed stream's next `.playing` beat
    /// re-reports start against the outgoing session id (`resolved` still points at
    /// it) — the server simply sees that session play again.
    ///
    /// If the failure hit at/after `engine.load`, `beginPlayback` already tore the
    /// engine down — nothing left to resume, so surface the fatal overlay exactly
    /// like before.
    private func fallBackAfterFailedSwitch(_ error: AppError) async -> TrackSwitchOutcome {
        // Exit can race the failed switch: beginExit() lands while the re-resolve is
        // suspended, and a real (non-cancellation) error then skips beginPlayback's
        // checkStillActive guards entirely. Resuming here would restart audio under
        // a dismissed player — stop() owns the teardown, so just walk away.
        guard !isExiting else { return .abandoned }
        guard let engine else {
            phase = .failed(error)
            await audioSession.deactivate()
            return .failed
        }
        phase = .playing
        await engine.play()
        return .fellBack(error)
    }

    // MARK: - Private

    private func subscribe(to engine: any PlaybackEngine) {
        let stream = engine.state
        stateTask = Task { [weak self] in
            for await state in stream {
                await self?.handle(state)
            }
        }
    }

    private func handle(_ state: PlaybackState) async {
        // While a transcode track switch reloads the reused engine, ignore the
        // outgoing stream's trailing beats — a stale `.playing` would claim the new
        // session's reportStart and the server would never register it starting.
        if isSwitchingTracks { return }
        // NOTE: do NOT gate the whole handler on `resolved` here. The SMB/local path
        // (`start(smbItem:)`) leaves `resolved` nil but still drives phase/position/
        // track/buffering beats through this surface. Each Jellyfin *reporting* call
        // below is gated on `resolved` individually instead — so a local session
        // updates the UI but never reports progress to a server it has none of.
        switch state {
        case .idle, .loading:
            break
        case .ready(_, let tracks):
            // For a transcode the menus are the server's FULL track list
            // (populated at resolve); the engine only sees the one baked-in
            // rendition, so don't let it overwrite them. Direct-play has every
            // track in the stream, so the engine's inventory is authoritative.
            // The SMB path (resolved == nil) is direct-play by nature: the engine's
            // inventory is authoritative and there are no external server subs to append.
            //
            // Track inventory resolves asynchronously (AVKit loads media
            // selection groups off the actor), so .ready can land *after*
            // .playing. Only publish the tracks — never regress phase back to
            // .loading, or the spinner would reappear over a playing video.
            if resolved?.method != .transcode {
                availableAudioTracks = tracks.audio
                // Embedded subs come from the engine; external sidecar subs are appended and
                // rendered client-side (the engine can't shape sidecar VTT on iOS). Both share
                // the chip menu. Jellyfin sources the externals from `resolved`; SMB (resolved
                // nil) uses the pre-built `smbExternalSubtitleTracks` — either way the engine's
                // embedded inventory can't clobber the sidecar picks.
                let externalSubs = resolved.map(Self.externalSubtitleTracks) ?? smbExternalSubtitleTracks
                availableSubtitleTracks = tracks.subtitles + externalSubs
                // Reflect the engine's default selection so the menus show a
                // checkmark on the track that's actually playing. Don't clobber
                // a choice the user already made (a late/duplicate .ready).
                if selectedAudioTrack == nil {
                    selectedAudioTrack = tracks.audio.first { $0.id == tracks.selectedAudioID }
                }
                if selectedSubtitleTrack == nil {
                    selectedSubtitleTrack = tracks.subtitles.first { $0.id == tracks.selectedSubtitleID }
                }
                // First inventory only: steer the engine's own picks toward the
                // user's Jellyfin language preferences (AVKit selects by system
                // language, not server config). Duplicate/late .ready beats and
                // post-switch reloads skip it. No-op when resolved == nil (SMB):
                // applyServerPreferredTracks guards on `resolved`.
                if !didApplyPreferredTracks {
                    didApplyPreferredTracks = true
                    await applyServerPreferredTracks()
                }
            }
        case .playing(let position, let duration, let buffered):
            phase = .playing
            // First `.playing` beat of this session: land the startup metric and consume
            // the anchor so a later `.playing` (resume-from-pause, post-stall) never
            // overwrites it. `nil` when this beat isn't the first (already consumed).
            if let clockStart = startupClockStart {
                startupClockStart = nil
                let elapsed = clockStart.duration(to: .now).components
                startupMillis = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            }
            // A scrub commit pins isPlaying to the user's intent across the engine's transient
            // pause/seek/resume beats (see scrubResumeIntent); the commit clears the latch when it
            // settles. nil = honor the beat directly.
            isPlaying = scrubResumeIntent ?? true
            clearStall()
            lastPosition = position
            currentPosition = position
            applyDuration(duration)
            bufferedTo = buffered
            nowPlaying.update(position: position, duration: duration, isPlaying: true, title: itemTitle)
            // Jellyfin: report to the server session. SMB: persist the position locally —
            // same beat, same ~10s throttle discipline as the progress report.
            if let resolved {
                if !didReportStart {
                    didReportStart = true
                    await playbackInfo.reportStart(beat(position: position, isPaused: false, from: resolved))
                    // First playing beat of this (fresh or track-switched) session: ffmpeg
                    // is now running, so probe what it's actually doing to the video.
                    startDeliveryProbe(for: resolved)
                } else {
                    await playbackInfo.reportProgress(beat(position: position, isPaused: false, from: resolved))
                }
            } else if smbSession != nil {
                saveSMBResumeThrottled()
            }
        case .paused(let position, let duration, let buffered):
            // While a scrub latch holds an intent, ignore the transient .paused beats the
            // drag/seek emit (they'd flash the glyph); the commit clears the latch when it
            // settles. nil = honor the beat directly. See scrubResumeIntent.
            isPlaying = scrubResumeIntent ?? false
            clearStall()
            lastPosition = position
            currentPosition = position
            applyDuration(duration)
            bufferedTo = buffered
            nowPlaying.update(position: position, duration: duration, isPlaying: false, title: itemTitle)
            // Never report progress for a session that never reported start (a remote/PiP
            // pause can land during buffering, before the first .playing beat) — Jellyfin
            // expects PlaybackStart before any Progress. Mirrors the .playing branch's gate.
            // The `if let resolved` also skips the SMB path, which has no server session —
            // it persists the pause point locally instead (same throttle; a pause right
            // before dismissal is covered by stop()'s final save, gated only on a nonzero
            // position — see stop()).
            if let resolved, didReportStart {
                await playbackInfo.reportProgress(beat(position: position, isPaused: true, from: resolved))
            } else if resolved == nil, smbSession != nil {
                saveSMBResumeThrottled()
            }
        case .buffering(let position, let duration, let buffered):
            // Phase and isPlaying are untouched: the surface stays up and the
            // user's intent is still "playing" — only the stall flag changes,
            // driving the light scrim. No progress report either: the position
            // isn't advancing, and a beat here could race reportStart.
            //
            // A position JUMP marks a seek fetch — the engine only emits those
            // when the target is outside the buffer, so the wait is real and the
            // scrim shows immediately (no 400ms gap with a bare paused glyph).
            // Contiguous-position beats (mid-stream underruns, the momentary
            // evaluating-buffering flicker after an in-buffer resume) keep the
            // debounce so they can't flash the scrim.
            let isSeekFetch = abs(CMTimeGetSeconds(position) - CMTimeGetSeconds(currentPosition)) > 2
            lastPosition = position
            currentPosition = position
            applyDuration(duration)
            bufferedTo = buffered
            if isSeekFetch {
                stallDebounceTask?.cancel()
                stallDebounceTask = nil
                isStalled = true
            } else {
                armStallDebounce()
            }
        case .ended:
            isPlaying = false
            scrubResumeIntent = nil   // a terminal beat drops any pending scrub latch
            clearStall()
            // Auto-advance: capture the target episode NOW and raise the loading veil
            // synchronously — both before the `await` below can yield. Capturing the id
            // pins the advance to THIS episode's neighbor: a manual prev/next during the
            // await would repoint `adjacentEpisodes`, so a late read would skip the wrong
            // way (or double-skip). Raising `.loading` here also stops `phase` lingering
            // at `.playing` + `isPlaying == false` across the hand-off — that flashed the
            // paused scrim before the next episode loaded (device-reported "pauses then
            // advances"). The veil then rides continuously through `resetForReplay`/`start`
            // into the next episode: one cover, no pause scrim, and (on the floor) no HUD.
            let advanceTarget = canAutoAdvance ? adjacentEpisodes.next?.id : nil
            if advanceTarget != nil {
                phase = .loading
            } else if !isExiting {
                // A movie or series finale ended with nowhere to go: dismiss the player
                // (the view watches this and runs the Close-chevron exit) rather than
                // leaving a stranded paused glyph on the last frame. Flip it BEFORE the
                // await so the paused overlay (gated on !playbackDidComplete) never paints
                // in the gap before the dismiss lands.
                playbackDidComplete = true
            }
            // SMB mirror of the stop report: a finished file restarts fresh. Clear the
            // session (nil'ing the id) BEFORE the store clear so stop()'s final save (the
            // dismiss lands right after) can't resurrect the position this just cleared;
            // `clearSMBSession` also awaits a stale throttled save so it can't outrun it.
            if let session = smbSession {
                let itemID = session.itemID
                await clearSMBSession()
                await smbResumeStore.clear(itemID)
            }
            await reportStoppedIfNeeded()
            // Deferred onto a fresh task so the in-flight `.ended` beat unwinds the engine's
            // state loop before the swap tears it down.
            if let advanceTarget {
                Task { [weak self] in await self?.replacePlayback(with: advanceTarget) }
            }
        case .failed(let error):
            isPlaying = false
            scrubResumeIntent = nil   // a terminal beat drops any pending scrub latch
            clearStall()
            phase = .failed(Self.map(error))
        }
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

    /// Builds the audio/subtitle menus from the server's full track list (used
    /// on the transcode path) and marks the active rendition. Track `id` is the
    /// source stream index — `selectAudioTrack`/`selectSubtitleTrack` feed it
    /// straight back to the server as `AudioStreamIndex`/`SubtitleStreamIndex`.
    ///
    /// Image subtitles (PGS/VobSub) are INCLUDED here, marked `isBurnedIn` —
    /// `DeviceProfileTranslator` declares them `.encode`, so the only way the
    /// server can deliver one is burned into the video. Picking one in
    /// `selectSubtitleTrack` re-resolves (like an audio switch), never happens by
    /// default (`applyTranscodeDefaultSubtitle` skips burned-in defaults — opt-in
    /// only), and forces a full re-encode (possibly HDR→SDR; jellyfin-tizen#202).
    private func populateTranscodeMenus(from resolved: ResolvedPlayback) {
        availableAudioTracks = resolved.mediaStreams
            .filter { $0.kind == .audio }
            .map { stream in
                // Mirrors DeviceProfileTranslator.transcodingProfile()'s audioCodec
                // ("aac,ac3,eac3") — exactly the codecs the HLS transcode stream-COPIES;
                // anything else is re-encoded to AAC (capped at 7.1). Keep in sync by hand.
                let copyCodecs: Set<String> = ["aac", "ac3", "eac3"]
                let isTranscode = !copyCodecs.contains((stream.codec ?? "").lowercased())
                return AudioTrack(
                    id: .jellyfinStream(stream.index),
                    displayName: stream.menuLabel,
                    languageCode: stream.language,
                    detailLabel: stream.trackDetailLabel,
                    isTranscode: isTranscode,
                    transcodeTarget: isTranscode ? "AAC" : nil
                )
            }
        availableSubtitleTracks = resolved.mediaStreams
            .filter { $0.kind == .subtitle }
            .map(Self.subtitleTrack(from:))

        selectedAudioTrack = availableAudioTracks.first { $0.id == currentAudioStreamIndex.map(TrackID.jellyfinStream) }
        selectedSubtitleTrack = availableSubtitleTracks.first { $0.id == currentSubtitleStreamIndex.map(TrackID.jellyfinStream) }
    }

    /// Resolution bucket. Delegates 4K to the shared `QualityBadge`, keeping the
    /// player-only sub-4K fallback detail hero metadata omits.
    private static func qualityLabel(width: Int?, height: Int?) -> String? {
        if let badge = QualityBadge.resolution(width: width, height: height) { return badge }
        let h = height ?? 0, w = width ?? 0
        if h >= 700 || w >= 1200 { return "720p" }
        if h > 0 { return "\(h)p" }
        return nil
    }

    /// HDR label — delegated to `QualityBadge.hdr`, which maps all HDR flavours
    /// (including `DOVIInvalid`) to `"HDR"`.
    private static func hdrLabel(_ range: String?) -> String? {
        QualityBadge.hdr(range)
    }

    private static func makeAsset(
        from resolved: ResolvedPlayback,
        subtitleFonts: SubtitleFontLocator.Fonts?
    ) -> PlayableAsset {
        PlayableAsset(
            url: resolved.url,
            headers: nil,
            hints: deliveredHints(for: resolved),
            // Every method resumes by SEEKING client-side. Jellyfin's HLS transcode
            // serves a full-timeline VOD playlist (position 0 = media start) and
            // ignores StartTimeTicks for the offset, so — exactly like direct-play —
            // the engine must seek to resolved.startTime on .ready. (Was nil for
            // transcode on the false "baked into the URL" assumption, which made
            // every transcode — first-play resume and post-track-switch — restart
            // at 0:00.)
            startTime: resolved.startTime,
            // Authoritative track names/languages — the engine uses these to
            // label tracks a transcode manifest left unnamed. (External subs aren't
            // passed to the engine at all — they're rendered client-side via
            // `externalSubtitleTracks` + `loadSidecarSubtitle`, like the transcode path.)
            mediaStreams: resolved.mediaStreams,
            defaultAudioStreamIndex: resolved.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: resolved.defaultSubtitleStreamIndex,
            // System fonts for VLC's text renderers (unused by AVKit). Materialized via
            // CoreText so we render with the OS fonts instead of bundling one: a font
            // directory for libass (ASS/SSA) and a single file for the simple renderer.
            // Resolved off-main by the caller (the first touch writes font files).
            subtitleFontURL: subtitleFonts?.primaryFile,
            subtitleFontsDirectoryURL: subtitleFonts?.directory
        )
    }

    /// External (sidecar) text subtitles from the server, as direct-play menu entries
    /// with `.jellyfinStream` ids. These render client-side (`SubtitleOverlayView`, fed by
    /// `loadSidecarSubtitle`) rather than through the engine — VLC can't shape sidecar VTT
    /// on iOS, and embedded subs already come from the engine's own inventory. Image subs
    /// are excluded (no client renderer for them yet). Labels come from the server, so they
    /// read "English" etc. instead of VLC's generic "Track N".
    private static func externalSubtitleTracks(from resolved: ResolvedPlayback) -> [SubtitleTrack] {
        resolved.mediaStreams
            .filter { $0.kind == .subtitle && $0.isExternal && !$0.isImageSubtitle }
            .map(Self.subtitleTrack(from:))
    }

    /// Sidecar formats `SubtitleOverlayView`'s client-side pipeline can actually parse
    /// (`SRTParser`/`WebVTTParser`). Case-insensitive extension check.
    private static let renderableSidecarExtensions: Set<String> = ["srt", "vtt"]

    /// SMB analog of `externalSubtitleTracks(from resolved:)` — there's no `resolved`
    /// stream list on the SMB path, only the filename-matched `[index: URL]` map + the
    /// resolver's `[index: label]`. Builds the same `.jellyfinStream`-id, client-rendered
    /// external tracks (so `selectSubtitleTrack` → `activateSidecarSubtitle` → the overlay
    /// path works identically) with the resolver's labels and the file extension as detail.
    /// Ordered by index for a stable menu.
    ///
    /// Filtered to `renderableSidecarExtensions`: the resolver's filename matcher also
    /// surfaces ASS/SSA sidecars (no client renderer yet — `SubtitleOverlayView` only
    /// parses SRT/VTT, so a selected ASS/SSA track would draw zero cues), but `subtitleURLs`
    /// itself stays unfiltered so a future VLC-native slaving task can still see those URLs.
    private static func externalSubtitleTracks(urls: [Int: URL], labels: [Int: String]) -> [SubtitleTrack] {
        urls.keys.sorted().compactMap { index -> SubtitleTrack? in
            guard let url = urls[index],
                  renderableSidecarExtensions.contains(url.pathExtension.lowercased())
            else { return nil }
            let format = url.pathExtension.uppercased()
            let detail = format.isEmpty ? "External" : "\(format) · External"
            return SubtitleTrack(
                id: .jellyfinStream(index),
                displayName: labels[index] ?? "Subtitle \(index + 1)",
                languageCode: nil,
                isForced: false,
                detailLabel: detail,
                isExternal: true,
                isSDH: false
            )
        }
    }

    /// Maps a server subtitle stream to a menu `SubtitleTrack` with a `.jellyfinStream` id
    /// (fed straight back to the server as `SubtitleStreamIndex` / to the sidecar loader).
    /// Shared by the transcode menu (all text subs, plus opt-in image subs) and the
    /// direct-play external-subs append (external TEXT only — `externalSubtitleTracks`
    /// filters image subs out before this ever sees one) so the two never drift in how
    /// a track is labeled.
    private static func subtitleTrack(from stream: MediaStreamInfo) -> SubtitleTrack {
        // Image subs only ever reach here via the transcode menu, where picking one
        // burns it into the video server-side instead of playing as "Embedded"/
        // "External" — the format alone is the detail line (what it's made of);
        // the "Burn-in" badge (below, `isBurnedIn`) carries the consequence, same
        // split as the audio menu's codec detail + "→ AAC" transcode badge.
        let detail = stream.isImageSubtitle
            ? TrackDisplay.subtitleFormatName(stream.codec)
            : stream.trackDetailLabel
        return SubtitleTrack(
            id: .jellyfinStream(stream.index),
            displayName: stream.menuLabel,
            languageCode: stream.language,
            isForced: stream.isForced,
            detailLabel: detail,
            isExternal: stream.isExternal,
            isSDH: stream.isHearingImpaired,
            isBurnedIn: stream.isImageSubtitle
        )
    }

    /// Format hints describing the *delivered* stream the engine selector must
    /// reason about — not necessarily the source. For `.transcode` the server
    /// delivers an HLS stream whose codecs target the AVKit whitelist (per the
    /// device profile), so gating on the source container/codecs (e.g. MKV / AV1
    /// / DTS) would wrongly route an AVKit-playable transcode to VLC and surface
    /// "unsupported format". Direct-play serves the source bytes verbatim, so its
    /// feasibility correctly gates on the source.
    private static func deliveredHints(for resolved: ResolvedPlayback) -> PlaybackHints {
        switch resolved.method {
        case .transcode:
            return PlaybackHints(
                scheme: resolved.url.scheme,
                container: .hls,
                videoCodec: nil,
                audioCodec: nil,
                subtitleFormats: []
            )
        case .directPlay:
            return PlaybackHints(
                scheme: resolved.url.scheme,
                container: resolved.container,
                videoCodec: resolved.videoCodec,
                audioCodec: resolved.audioCodec,
                subtitleFormats: []
            )
        }
    }

    private static func map(_ error: PlaybackError) -> AppError {
        switch error {
        case .assetNotPlayable:
            return .playback(.decodeFailed)
        case .networkStalled:
            return .playback(.resourceUnavailable)
        case .unknown:
            return .playback(.decodeFailed)
        }
    }
}

#if DEBUG
extension PlayerViewModel {
    /// The resolved server-side playback metadata for the playing item.
    /// Debug HUD only — exposes the otherwise-private `resolved`.
    var debugResolved: ResolvedPlayback? { resolved }

    /// The active stream-index → sidecar subtitle URL map. Test-only window onto
    /// the private `subtitleURLs` so the SMB-start tests can assert it's populated
    /// from the item and cleared on `stop()`.
    var debugSubtitleURLs: [Int: URL] { subtitleURLs }

    /// The active engine's id, for the HUD's engine label.
    var debugEngineID: PlaybackEngineID? { engine?.id }

    /// The engine's live decode snapshot (actual dimensions, bitrates, the true
    /// audio/subtitle selection). Polled by the HUD.
    func currentDebugSnapshot() async -> PlaybackDebugInfo {
        await engine?.debugSnapshot() ?? .empty
    }

    /// Whether the active subtitle is one WE draw (`SubtitleOverlayView` renders the
    /// sidecar cues) rather than the engine — true exactly when the selection carries a
    /// `.jellyfinStream` id (transcode text subs + direct-play externals). Keying on the
    /// SELECTION (intent) rather than on `activeSubtitleCues` (the fetched effect) means a
    /// nudge during the sidecar's fetch window still routes to the client offset.
    var usesClientSubtitleRendering: Bool { selectedSubtitleTrack?.id.jellyfinStreamIndex != nil }

    /// Live subtitle-delay nudge (`ms` absolute, positive = later). Routes to whichever
    /// renderer owns the active subtitle: client-drawn sidecar cues retime in
    /// `SubtitleOverlayView` via `clientSubtitleDelayMs`; an engine-rendered (embedded)
    /// track retimes in the engine itself (VLC; AVKit ignores).
    func setSubtitleDelay(ms: Int) async {
        if usesClientSubtitleRendering {
            clientSubtitleDelayMs = ms
        } else {
            await engine?.setSubtitleDelay(milliseconds: ms)
        }
    }
}

// MARK: - Preview support

/// A view model frozen in a live `.playing` state with representative tracks, for the
/// HUD `#Preview`s (`PlayerControlsView`). No engine, no network: the display fields are
/// set directly. The injected deps are inert stubs never exercised (playback never
/// starts), so this render exercises the chrome layout alone.
extension PlayerViewModel {
    @MainActor
    static func previewPlaying() -> PlayerViewModel {
        let vm = PlayerViewModel(
            deviceProfileBuilder: DeviceProfileBuilder(probe: LiveCapabilityProbe()),
            playbackInfo: NoOpPlaybackReporting(),
            resolve: { _, _, _, _, _ in throw AppError.playback(.unsupportedFormat) },
            engineFactory: { _ in fatalError("preview VM never starts playback") },
            audioSession: PreviewAudioSession()
        )
        vm.itemTitle = "The Grand Budapest Hotel"
        vm.phase = .playing
        vm.isPlaying = true
        vm.currentDuration = CMTime(seconds: 5_460, preferredTimescale: 600)   // 1:31:00
        vm.currentPosition = CMTime(seconds: 1_920, preferredTimescale: 600)   // 0:32:00
        let audio = AudioTrack(id: .jellyfinStream(1), displayName: "English",
                               languageCode: "eng", detailLabel: "TrueHD · 7.1")
        vm.availableAudioTracks = [audio]
        vm.selectedAudioTrack = audio
        let subtitle = SubtitleTrack(id: .jellyfinStream(2), displayName: "English",
                                     languageCode: "eng", isForced: false,
                                     detailLabel: "SRT · External", isExternal: true)
        vm.availableSubtitleTracks = [subtitle]
        vm.selectedSubtitleTrack = subtitle
        return vm
    }
}

private struct PreviewAudioSession: AudioSessionControlling {
    func activate() async throws {}
    func deactivate() async {}
    let routeChanges = AsyncStream<Void> { _ in }
}
#endif

import Foundation
import MediaPlayer
import Observation
import os
import CoreMedia
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

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

    /// The playing item's title — surfaced in the player's top bar.
    var title: String { itemTitle }

    /// Caption for the loading scrim. A transcode audio switch reloads the
    /// stream ("Switching audio · <track>"); a mid-stream stall over a live frame
    /// is "Buffering"; a first play is "Loading video".
    var loaderTitle: String {
        if isSwitchingTracks { return "Switching audio" }
        if showsStallScrim { return "Buffering" }
        return "Loading video"
    }
    var loaderSubtitle: String? { isSwitchingTracks ? selectedAudioTrack?.displayName : nil }

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

    /// A transcode audio switch that failed AFTER playback safely resumed on the
    /// previous track (the design's silent fallback). Drives the "Couldn't switch
    /// audio" scrim: `retryFailedTrackSwitch()` re-attempts the same track,
    /// `dismissTrackSwitchFailure()` keeps the current one. Nil when no failed
    /// switch is pending. Fatal failures (engine lost mid-reload) never set this —
    /// they go through `phase = .failed` and the general error scrim.
    struct TrackSwitchFailure {
        /// The track the user asked for — the retry target.
        let requested: AudioTrack
        /// The track playback stayed on. Nil when the previous selection is unknown.
        let fallback: AudioTrack?
        let error: AppError
    }
    private(set) var trackSwitchFailure: TrackSwitchFailure?

    /// Re-attempt the failed switch with the same track.
    func retryFailedTrackSwitch() async {
        guard let failure = trackSwitchFailure else { return }
        trackSwitchFailure = nil
        await selectAudioTrack(failure.requested)
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
        await engine?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Optimistic transport toggle: flip `isPlaying` to the target NOW so the
    /// play/pause glyph swaps on the tap itself, then command the engine. The
    /// next engine beat (.playing/.paused) confirms or corrects — `handle()`
    /// stays the source of truth; this only removes the tap→engine→beat
    /// round-trip from the button (play especially: AVPlayer emits no beat
    /// until its transport actually flips, hundreds of ms on a transcode).
    ///
    /// Spam-safe by cancel-previous coalescing: each tap retargets ONE
    /// `transportTask`, so a burst of taps flips the glyph with every press
    /// (parity — instant, like the system player) but only the LAST intent is
    /// still alive to command the engine; stale commands die before their
    /// `await`. The synchronous flip happens before any suspension, so intent
    /// order can't interleave.
    ///
    /// The scrub and reducer pause/resume paths must KEEP commanding the
    /// engine directly: they capture `isPlaying` as resume intent, and an
    /// optimistic write there would corrupt the capture.
    func togglePlayPause() {
        guard engine != nil else { return }
        isPlaying.toggle()
        let target = isPlaying
        transportTask?.cancel()
        transportTask = Task {
            // Re-read the engine at execution time: a pending command after
            // stop() must no-op, not poke a torn-down engine.
            guard !Task.isCancelled, let engine else { return }
            if target { await engine.play() } else { await engine.pause() }
        }
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
    private var didReportStart = false
    private var didReportStopped = false
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

    // Transcode track switching: the server bakes one audio + only text subs
    // into a transcode, so switching tracks means re-resolving the stream around
    // a different source index. We keep the item + the current indices to rebuild.
    private var playingItem: ItemDetail?
    /// The id requested via `start(itemID:)`, kept so `retry()` can re-fetch when
    /// the original failure was the detail fetch itself (no `playingItem` yet).
    private var pendingItemID: ItemID?
    private var currentAudioStreamIndex: Int?
    private var currentSubtitleStreamIndex: Int?

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
        keepaliveInterval: Duration = .seconds(30)
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
        guard let segment = activeSegment, segment.kind.playerAction == .skip, let engine else { return }
        await engine.seek(to: CMTime(seconds: segment.endSeconds, preferredTimescale: 600))
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
        case .episode(let d):
            positionTicks = d.episode.userData.playbackPositionTicks
            runtime = d.episode.runtime
            itemTitle = d.episode.name
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
                onSeek: { [weak self] time in Task { await self?.engine?.seek(to: time) } },
                onPlay: { [weak self] in Task { await self?.engine?.play() } },
                onPause: { [weak self] in Task { await self?.engine?.pause() } }
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
        if let engine {
            await engine.teardown()
            self.engine = nil
        }
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
        stateTask?.cancel()
        stateTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        transportTask?.cancel()
        transportTask = nil
        if let engine {
            await engine.teardown()
        }
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
        currentAudioStreamIndex = nil
        currentSubtitleStreamIndex = nil
        availableAudioTracks = []
        availableSubtitleTracks = []
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        trackSwitchFailure = nil
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        activeSubtitleCues = []
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
        await resetForReplay()
        if let item { await start(item: item) }
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
                trackSwitchFailure = TrackSwitchFailure(requested: track, fallback: previous, error: error)
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
        // A `.jellyfinStream` id is an external/sidecar text sub we render ourselves
        // (transcode: every text sub; direct-play: the external ones) — fetch + draw it
        // via SubtitleOverlayView with the engine's own subtitle held off. An embedded
        // direct-play track carries a `.vlc`/`.avKitOption` id the engine renders; `nil`
        // is Off.
        if let track, let index = track.id.jellyfinStreamIndex {
            await activateSidecarSubtitle(track, index: index)
        } else if resolved?.method == .transcode {
            // Transcode Off: no engine subtitle exists (subs never ride the manifest),
            // so just drop the overlay and record Jellyfin's "no subtitle" sentinel.
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
    /// default is surfaced here as the initial sidecar selection. Text subs
    /// only: image subs never enter `availableSubtitleTracks`, so a PGS default
    /// quietly stays off (burn-in is a later phase).
    private func applyTranscodeDefaultSubtitle(from resolved: ResolvedPlayback) async {
        guard let index = resolved.defaultSubtitleStreamIndex,
              let track = availableSubtitleTracks.first(where: { $0.id == .jellyfinStream(index) })
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

        // SUBTITLES — only when the server's mode+language logic says one should
        // show, and the engine didn't already auto-select one (AVKit honors the
        // system's accessibility caption setting; never fight that).
        guard selectedSubtitleTrack == nil,
              let index = resolved.defaultSubtitleStreamIndex,
              let preferred = resolved.mediaStreams.first(where: { $0.kind == .subtitle && $0.index == index })
        else { return }
        if let external = availableSubtitleTracks.first(where: { $0.id == .jellyfinStream(index) }) {
            // External sidecar subs carry their Jellyfin index — exact match, rendered
            // client-side like every external pick (engine subtitle held off so VLC's
            // late-discovered embedded default can't show through it).
            await activateSidecarSubtitle(external, index: index)
        } else if let match = availableSubtitleTracks.first(where: {
            !$0.isExternal
                && TrackLanguage.matches($0.languageCode, preferred.language)
                && $0.isForced == preferred.isForced
        }) {
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
        guard let url = resolved?.subtitleStreamURLs[streamIndex] else {
            activeSubtitleCues = []
            return
        }
        let fetch = subtitleFetch
        subtitleFetchTask = Task { [weak self] in
            guard let data = await fetch(url) else { return }
            let cues = WebVTTParser.parse(data: data)
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

    /// Rebuilds the transcode around new stream indices, resuming at the current
    /// position. Costs a brief re-buffer — the server has to re-encode around the
    /// chosen track. The engine instance is REUSED (reloaded), so the video surface
    /// stays mounted and holds the last frame through the swap instead of blinking to
    /// black; the audio session stays active too.
    private func switchTranscodeTrack(audioStreamIndex: Int?, subtitleStreamIndex: Int?) async -> TrackSwitchOutcome {
        // The chips stay mounted through a switch's .loading phase now — a second
        // pick mid-switch must wait for (not race) the in-flight reload.
        guard !isSwitchingTracks, let item = playingItem else { return .abandoned }
        // The transcode plays a full-timeline HLS playlist that the engine SEEKS to
        // the resume offset (Jellyfin ignores StartTimeTicks for the playlist start),
        // so currentPosition is already absolute media time — resume the new stream
        // right there. (Adding the old origin double-counted it, so resume drifted
        // further forward on every track switch.)
        let resumePosition = currentPosition

        // Keep the engine + its layer alive across the switch (beginPlayback reloads
        // it). Suppress the outgoing stream's trailing beats while we do.
        isSwitchingTracks = true
        defer { isSwitchingTracks = false }

        // Freeze the current frame at the moment of selection — the frosted cover
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
        // than every successful switch livelocking.
        await stopEncodingIfNeeded()
        await reportStoppedIfNeeded()
        didReportStart = false
        didReportStopped = false
        didStopEncoding = false

        do {
            try await beginPlayback(
                item: item,
                startTime: resumePosition,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                reusingEngine: true
            )
            return .completed
        } catch is CancellationError {
            // Exit raced the track switch — stop() already owns the teardown.
            return .abandoned
        } catch let error as AppError {
            return await fallBackAfterFailedSwitch(error)
        } catch {
            Log.playback.error("track switch failed: \(error.networkDiagnostic)")
            return await fallBackAfterFailedSwitch(
                .unexpected("track switch failed", underlying: AnySendableError(error))
            )
        }
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
        guard let resolved else { return }
        switch state {
        case .idle, .loading:
            break
        case .ready(_, let tracks):
            // For a transcode the menus are the server's FULL track list
            // (populated at resolve); the engine only sees the one baked-in
            // rendition, so don't let it overwrite them. Direct-play has every
            // track in the stream, so the engine's inventory is authoritative.
            //
            // Track inventory resolves asynchronously (AVKit loads media
            // selection groups off the actor), so .ready can land *after*
            // .playing. Only publish the tracks — never regress phase back to
            // .loading, or the spinner would reappear over a playing video.
            if resolved.method != .transcode {
                availableAudioTracks = tracks.audio
                // Embedded subs come from the engine; external sidecar subs are appended
                // from the server list and rendered client-side (the engine can't shape
                // sidecar VTT on iOS). Both share the chip menu.
                availableSubtitleTracks = tracks.subtitles + Self.externalSubtitleTracks(from: resolved)
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
                // post-switch reloads skip it.
                if !didApplyPreferredTracks {
                    didApplyPreferredTracks = true
                    await applyServerPreferredTracks()
                }
            }
        case .playing(let position, let duration, let buffered):
            phase = .playing
            isPlaying = true
            clearStall()
            lastPosition = position
            currentPosition = position
            applyDuration(duration)
            bufferedTo = buffered
            nowPlaying.update(position: position, duration: duration, isPlaying: true, title: itemTitle)
            if !didReportStart {
                didReportStart = true
                await playbackInfo.reportStart(beat(position: position, isPaused: false, from: resolved))
            } else {
                await playbackInfo.reportProgress(beat(position: position, isPaused: false, from: resolved))
            }
        case .paused(let position, let duration, let buffered):
            isPlaying = false
            clearStall()
            lastPosition = position
            currentPosition = position
            applyDuration(duration)
            bufferedTo = buffered
            nowPlaying.update(position: position, duration: duration, isPlaying: false, title: itemTitle)
            // Never report progress for a session that never reported start (a remote/PiP
            // pause can land during buffering, before the first .playing beat) — Jellyfin
            // expects PlaybackStart before any Progress. Mirrors the .playing branch's gate.
            if didReportStart {
                await playbackInfo.reportProgress(beat(position: position, isPaused: true, from: resolved))
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
            await reportStoppedIfNeeded()
            // Deferred onto a fresh task so the in-flight `.ended` beat unwinds the engine's
            // state loop before the swap tears it down.
            if let advanceTarget {
                Task { [weak self] in await self?.replacePlayback(with: advanceTarget) }
            }
        case .failed(let error):
            isPlaying = false
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
    /// Image subtitles (PGS/VobSub) are dropped: the server can only deliver them
    /// by burning into the video, which this phase deliberately doesn't do. Only
    /// text subs (carried in the HLS manifest) are offered until burn-in lands.
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
            .filter { $0.kind == .subtitle && !$0.isImageSubtitle }
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

    /// Maps a server subtitle stream to a menu `SubtitleTrack` with a `.jellyfinStream` id
    /// (fed straight back to the server as `SubtitleStreamIndex` / to the sidecar loader).
    /// Shared by the transcode menu (all text subs) and the direct-play external-subs
    /// append (external only) so the two never drift in how a track is labeled.
    private static func subtitleTrack(from stream: MediaStreamInfo) -> SubtitleTrack {
        SubtitleTrack(
            id: .jellyfinStream(stream.index),
            displayName: stream.menuLabel,
            languageCode: stream.language,
            isForced: stream.isForced,
            detailLabel: stream.trackDetailLabel,
            isExternal: stream.isExternal,
            isSDH: stream.isHearingImpaired
        )
    }

    /// Format hints describing the *delivered* stream the engine selector must
    /// reason about — not necessarily the source. For `.transcode` the server
    /// delivers an HLS stream whose codecs target the AVKit whitelist (per the
    /// device profile), so gating on the source container/codecs (e.g. MKV / AV1
    /// / DTS) would wrongly route an AVKit-playable transcode to VLC and surface
    /// "unsupported format". Direct-play/-stream serve the source bytes verbatim,
    /// so their feasibility correctly gates on the source.
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
        case .directPlay, .directStream:
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
        case .assetNotPlayable, .decodeFailed:
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
#endif

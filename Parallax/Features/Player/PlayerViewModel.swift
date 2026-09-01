import Foundation
import MediaPlayer
import Observation
import os
import CoreMedia
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback
import ParallaxSubtitles

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

    /// `didSet` rather than a line at each of the ten `phase = .failed` sites: a failed session
    /// publishes no further position beat, so a seek hold left standing has nothing left that
    /// could ever hand the bar back — it would ride under the error scrim and into the retry as
    /// a resume point nothing played. Every route into `.failed` owes that, and a rule the
    /// property enforces cannot be forgotten by the next one.
    private(set) var phase: Phase = .idle {
        didSet {
            if case .failed = phase { seekHold = nil }
        }
    }
    /// The engine this session is driving. Read-only here: `engineSlot` owns the
    /// lifetime, and every build/retire goes through it, so "never nil between the first
    /// `loadAndPlay` and `stop()`" is an invariant one type enforces rather than a rule
    /// four call sites remember. Observable through the slot — a view reading this reads
    /// `EngineSlot.current`, so a swap re-renders the host exactly as a stored property
    /// would.
    var engine: (any PlaybackEngine)? { engineSlot.current }

    private let engineSlot = EngineSlot()

    /// The libvlc instance arguments `engine` was BUILT with, so `loadAndPlay` can tell a
    /// reusable engine from a stale one. Instance-scoped options are fixed at construction
    /// (`VLCKitEngine.init(libraryOptions:)`), and every VLC asset now carries some — the
    /// subtitle look moved there — so "reuse only when the asset has none" would never reuse
    /// again and every episode change would rebuild the player. Tracked here rather than on
    /// the `PlaybackEngine` protocol: it is an app-side reuse policy, and AVKit has no such
    /// concept. Only ever read next to a live `engine` (the reuse test binds one first), and
    /// rewritten by every construction, so a teardown has nothing to clear here.
    private var engineLibraryOptions: [String]?
    var isPiPAvailable: Bool { engine?.capabilities.supportsPiP ?? false }
    var isVideoAirPlayAvailable: Bool { engine?.capabilities.supportsVideoAirPlay ?? false }

    /// PiP start/stop actions, pushed up from the video host once its
    /// PiP controller is ready (AVKit: `onPiPReady`; VLC: `VLCPictureInPictureDrawable`).
    /// Nil until a host mounts — so `startPiP()`/`stopPiP()` are safe no-ops in tests.
    var startPiPAction: (@MainActor () -> Void)?
    var stopPiPAction: (@MainActor () -> Void)?
    func startPiP() { startPiPAction?() }
    func stopPiP() { stopPiPAction?() }

    /// Freeze/unfreeze the video surface's last frame, pushed up from the video host
    /// (`onFreezeReady`) like the PiP actions, and nil until a host mounts, so both are
    /// safe no-ops in tests. The VM freezes at the top of an engine-reusing reload
    /// (`reloadTranscode`) and unfreezes on the swapped-in session's first LIVE beat
    /// (`.playing` OR `.paused`, since a paused scrub's re-anchor is re-paused and never
    /// plays), keeping the last frame under the "Buffering" veil instead of the black
    /// `replaceCurrentItem` flush. `surfaceFrozen` gates the beat-side unfreeze so
    /// ordinary beats never call into the host.
    ///
    /// `beginExit()` freezes too and never unfreezes: the engine stops under the surface
    /// to end audio (VLC closes its vout with it), and the still is what the card slides
    /// out on. Both hosts wire it for that reason.
    var freezeSurfaceAction: (@MainActor () -> Void)?
    var unfreezeSurfaceAction: (@MainActor () -> Void)?
    private var surfaceFrozen = false
    private func freezeVideoSurface() {
        guard !surfaceFrozen else { return }
        surfaceFrozen = true
        freezeSurfaceAction?()
    }
    /// The exit fence lives HERE, not at the call sites, because the exit freeze has to
    /// survive beats that arrive after it: AVKit's default `endAudio()` funnels to
    /// `pause()`, which emits a `.paused` beat synchronously, and VLC's poll swallows its
    /// own cancellation in a `try?` sleep for one more tick. Either would crossfade the
    /// still away mid-slide-out, onto a vout that is already closing: a visible cut to
    /// black. `stop()` is fenced by the same flag; the one path that comes back
    /// (`retry()`/`replacePlayback` → `resetForReplay`) releases the frame itself, right
    /// after it disarms the fence and before the fresh `start`.
    private func unfreezeVideoSurface() {
        guard !isExiting, surfaceFrozen else { return }
        surfaceFrozen = false
        unfreezeSurfaceAction?()
    }
    private(set) var availableAudioTracks: [AudioTrack] = []
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var selectedAudioTrack: AudioTrack? = nil
    private(set) var selectedSubtitleTrack: SubtitleTrack? = nil
    /// The client-side renderer (libass, `ParallaxSubtitles`) for the active sidecar
    /// subtitle that `SubtitleOverlayView` draws: used by the transcode path AND by
    /// direct-play EXTERNAL subs (VLC can't shape sidecar text on iOS). Nil when no
    /// such subtitle is active — including direct-play EMBEDDED subs, which the engine
    /// renders itself. This is how we sidestep the in-manifest WebVTT drift
    /// (jellyfin/jellyfin#16647) while keeping authored ASS styling intact.
    private(set) var subtitleRenderer: SubtitleRenderer?
    /// Format + size the renderer was loaded with — debug panel and the style-override
    /// policy read it. Nil ⟺ `subtitleRenderer` is nil.
    private(set) var sidecarSubtitleInfo: SidecarSubtitleInfo?
    /// Monotonic token bumped on every renderer install/clear. The overlay keys its
    /// canvas pushes on this instead of object identity — a freed actor's address can
    /// be reused by its replacement, which would silently skip the new canvas push
    /// and leave the fresh renderer with a zero canvas (permanently blank subtitles).
    private(set) var subtitleRendererGeneration = 0
    /// The subtitle track whose sidecar is being fetched right now — the subtitle chip
    /// spins on its own glyph, and the menu row's check column with it. A cold EMBEDDED
    /// Jellyfin stream is extracted by ffmpeg on first request, which can take seconds —
    /// silence there is what makes the wait read as a bug rather than a fetch.
    var loadingSubtitleTrackID: TrackID? {
        sidecarFetchStreamIndex.map(TrackID.jellyfinStream)
    }
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
        return (end / dur).unitClamped
    }

    /// Where playback HONESTLY is, as opposed to where the bar is currently promising it will
    /// be. The two come apart for exactly one window: `currentPosition` is overwritten with the
    /// seek target on the beat a commit arms its flight, so from that instant until the engine
    /// takes the seek it reads a place the picture has not reached — while the flight still
    /// carries the position it jumped away from, which is where the picture actually sits.
    ///
    /// `.landing` is where that stops being true: a `.projected` beat is the engine's estimate
    /// off its OWN seek target, which the seek-settle contract calls display-safe — the picture
    /// is at (or running from) it. From that beat the published clock is honest again, so the
    /// concrete indicator follows it instead of claiming the video never moved for the whole
    /// multi-second settle window a VLC re-anchor takes.
    ///
    /// Two readers, and they have to be the same expression or the bar contradicts itself: the
    /// CONCRETE indicator draws this during a gesture (`PlayerProgressBar.init(scrubbingTo:vm:)`),
    /// and every new flight anchors its `played` on it (`beginPreview`, `commitScrubSeek`) — so a
    /// scrub made over a seek that never landed CHAINS back to the original A instead of claiming
    /// a B nothing ever played, and the crossing it commits starts from the dot the user has been
    /// looking at. That is the whole chaining rule, and it exists only here.
    var concretePosition: CMTime {
        guard let flight else { return currentPosition }
        return flight.stage == .landing ? currentPosition : flight.played
    }

    /// The committed seek as the bar draws it: the 0...1 fractions the playhead jumped between,
    /// plus the flight's identity. Live from the commit until the engine lands, nil while a
    /// gesture is still previewing (nothing is in flight yet) and whenever the runtime isn't
    /// scrubbable. Read by `ScrubDeltaPulse`, which sweeps the segment from `from` toward `to`,
    /// and by the concrete indicator's crossing, which animates on `id`.
    var seekSpan: SeekSpan? {
        guard let flight, flight.stage != .previewing, hasKnownDuration else { return nil }
        let dur = CMTimeGetSeconds(currentDuration)
        let from = CMTimeGetSeconds(flight.played) / dur
        let to = CMTimeGetSeconds(flight.requested) / dur
        guard from.isFinite, to.isFinite else { return nil }
        return SeekSpan(id: flight.id,
                        delta: SeekDelta(from: from.unitClamped, to: to.unitClamped))
    }
    /// Whether the ENGINE is actively playing (vs paused): a mirror driven by its beats,
    /// so it necessarily LAGS: VLC polls its transport every 500ms behind a seek-settlement
    /// gate (measured at ~5s on wmv/SMB), AVKit emits nothing until a re-buffer ends.
    ///
    /// NO user-facing surface reads it. Every transport surface (the play/pause glyph, the
    /// tvOS paused overlay, the chrome auto-hide timers) reads `desiredPlaying` instead:
    /// intent is synchronous and exact, the mirror is neither, and every attempt to paper
    /// over the gap in the UI (a scrub-resume suppression flag, a beat-pinning latch) turned
    /// into its own starvation bug inside a slow engine's settle window. What's left here is
    /// diagnostics: the Playback Lab dump and the tests that assert the engine's own view.
    private(set) var isPlaying: Bool = false

    /// The user's TRANSPORT INTENT: what playback should be doing once the engine catches
    /// up. Written only by explicit transport commands (`setPlaying`), by starting playback,
    /// by the terminal beats that end a session, and by the engine-initiated resumes that
    /// restore this same intent after a stumble (`fallBackAfterFailedSwitch`, which resumes
    /// the outgoing stream when a track switch fails to load). Ordinary engine beats never
    /// touch it, and neither does scrub machinery: the drag's entry pause and the tvOS reducer's `.pause` effect are
    /// temporary holds on a still frame, and surviving them is exactly the point.
    ///
    /// Every scrub surface captures its resume intent from HERE. Capturing `isPlaying`
    /// instead was the bug: a second scrub inside the mirror's lag window read `false`, so its
    /// commit seeked without resuming and playback stuck on the pause the scrub itself had
    /// issued (usually from the second scrub after playback starts, both engines, all platforms).
    private(set) var desiredPlaying: Bool = false

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
        if isReanchoring { return LoaderCaption.buffering }
        if isSwitchingTracks { return LoaderCaption.switchingAudio }
        if showsStallScrim { return LoaderCaption.buffering }
        return LoaderCaption.loadingVideo
    }

    /// The scrim's three captions, named so the view's fallback and the tests
    /// reference one source instead of re-typing the user-facing strings.
    enum LoaderCaption {
        static let buffering = "Buffering"
        static let switchingAudio = "Switching audio"
        static let loadingVideo = "Loading video"
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
        /// carries none either — `TrackMenuRowID.subtitlesOff`), hence `id` below.
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

    /// The user's subtitle-delay nudge (ms) for the item being played. The ENGINE's
    /// copy is input-scoped and reset by every `load()`, so the intent lives here —
    /// per item, like the pick itself — and `loadAndPlay` re-applies it after a
    /// same-item reload (transcode swap, track switch). Cleared when the item changes
    /// (`replacePlayback`); a retry of the same item keeps it, like `playbackRate`.
    private(set) var subtitleDelayMs = 0

    /// The just-loaded asset itself — kept so a reactive AVKit→VLC re-route
    /// (`attemptReactiveFallback`) can rebuild it (same url/headers/hints/vlcOptions,
    /// forced onto VLCKit) and so `ReactiveFallback.shouldReroute` can read its container
    /// back off `hints`, without threading a duplicate copy through every play path.
    /// Set at the top of `loadAndPlay` (every play path funnels through there); cleared
    /// with the rest of the per-session state in `stop()`.
    private var currentAsset: PlayableAsset?

    /// One-shot latch for the reactive AVKit→VLC fallback (`attemptReactiveFallback`):
    /// true once THIS session has already spent its single re-route, so a second
    /// terminal failure (on VLC, or on a second MP4 defect) falls through to the normal
    /// error scrim instead of retrying forever. Reset with the rest of the per-session
    /// state in `stop()`.
    private var didReactivelyReroute = false

    /// The engine session this view model is driving — `engine.load()`'s return value, and
    /// the ONE thing `handle` checks a beat against. An engine is reloadable in place, so the
    /// engine's own identity cannot answer "is this beat about the media I am playing now?":
    /// a re-anchor keeps the engine, its stream and its buffered beats, and the outgoing
    /// media's callbacks stay live for seconds after the reload arms (a status KVO enqueued on
    /// the run loop, an inventory load mid-await, an armed watchdog).
    ///
    /// It replaces the flags this view model used to raise around a reload and a reroute. Those
    /// were read where a beat is CONSUMED while being cleared on the reload's own timeline, so a
    /// beat the dying session published while a flag was up could take its MainActor turn after
    /// the flag came down and be honored as the live session's — on a re-anchor that beat is a
    /// `.failed`, because the reload kills the outgoing encode job before the replacement
    /// resolves, and the error scrim lands over a reload that is buffering perfectly well.
    /// Nil before the first load and after a teardown: nothing to adopt.
    private(set) var activeSession: PlaybackSessionID?

    /// The session a RELOAD opened has not published a live beat yet. Armed at the session
    /// transition, and only where the outgoing frame is frozen under the reload cover — a cold
    /// start and the auto-advance veil hold no frame — then consumed by that session's first
    /// `.playing`/`.paused` beat.
    ///
    /// That beat carries two decisions a re-anchor cannot make any other way. It takes the
    /// cover down: the reload force-resumes and `commitScrubSeek` re-pauses it, so a scrub
    /// committed while PAUSED can go its whole life without ever publishing `.playing`, and the
    /// heavy cover then sits over a rendered, healthy frame forever. And it opens the session
    /// for reporting: the reload reset `didReportStart`, so with only `.playing` allowed to
    /// report a start, Jellyfin never learned the new session at all — no progress, no stop
    /// report, and the position the user re-anchored to was never persisted.
    private var reloadAwaitingFirstLiveBeat = false

    /// The reactive-fallback hop `.failed` spawns (`attemptReactiveFallback`), stored so
    /// `stop()` can cancel it — closing the window where `retry()`/`resetForReplay` tear
    /// the session down while a pending hop is still in flight and would otherwise build
    /// a VLC engine for a session that's already gone.
    private var reactiveFallbackTask: Task<Void, Never>?

    /// Wall-clock milliseconds from `engine.play()` dispatch to this session's FIRST
    /// `.playing` beat — the debug overlay's `Startup:` row (Plan C, AVKit startup
    /// tuning A/B). `nil` before the first beat lands and reset per session/reload
    /// (see `startupClockStart`). Engine-agnostic: set for VLCKit sessions too, though
    /// only AVKit is presently tunable.
    private(set) var startupMillis: Int?

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
    /// Cached, not computed-per-read: the scrubber body re-evaluates ~2 Hz off the
    /// periodic time observer, and this maps every
    /// chapter through a divide. Recomputed only when the chapter set (`playingItem`) or
    /// the duration actually changes — see `recomputeChapterFractions` / `applyDuration`.
    private(set) var chapterFractions: [Double] = []

    private func recomputeChapterFractions() {
        let dur = CMTimeGetSeconds(currentDuration)
        guard dur > 0 else { chapterFractions = []; return }
        chapterFractions = chapters.map { chapter in
            let c = chapter.start.components
            let s = Double(c.seconds) + Double(c.attoseconds) / 1e18
            return (s / dur).unitClamped
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
        // Transport-preserving: a paused chapter jump must stay paused across an
        // out-of-buffer re-anchor (whose reload force-resumes).
        await seekPreservingTransport(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Optimistic transport toggle from the play/pause button. Flips to the opposite of the
    /// user's INTENT (`desiredPlaying`), never the engine mirror: inside the mirror's lag
    /// window (wmv/VLC settles for seconds) `isPlaying` can still read the pre-command value,
    /// so toggling off it did the exact opposite of what the press asked for.
    func togglePlayPause() {
        setPlaying(!desiredPlaying)
    }

    /// Drive the transport to an explicit play state NOW so the play/pause glyph swaps on the
    /// tap itself, then command the engine. The next engine beat (.playing/.paused) confirms or
    /// corrects — `handle()` stays the source of truth; this only removes the tap→engine→beat
    /// round-trip from the button (play especially: AVPlayer emits no beat until its transport
    /// actually flips, hundreds of ms on a transcode).
    ///
    /// Shared by the button (`togglePlayPause`) AND the Now Playing remote commands so EVERY
    /// explicit transport intent lands the same way: a remote pause/play arriving in the
    /// scrub-commit window rewrites the intent every transport surface reads, so it shows on
    /// the press instead of waiting for a beat that AVKit never sends while paused.
    ///
    /// Spam-safe by cancel-previous coalescing: each call retargets ONE `transportTask`, so a
    /// burst flips the glyph with every press (parity — instant, like the system player) but only
    /// the LAST intent is still alive to command the engine; stale commands die before their
    /// `await`. The synchronous flip happens before any suspension, so intent order can't interleave.
    ///
    /// The scrub and reducer pause/resume paths must KEEP commanding the engine directly: they
    /// are transient holds on a still frame, and routing them here would overwrite the very
    /// intent (`desiredPlaying`) their commit is about to replay.
    func setPlaying(_ playing: Bool) {
        guard engine != nil else { return }
        // Same exit fence the scrub/seek surfaces carry: a Now Playing or lock-screen play
        // command can land inside the dismiss animation (the remote commands stay registered
        // until `stop()` clears them), and on AVKit nothing downstream would stop it from
        // resuming audible playback under a player that is already sliding away. VLC is only
        // saved by its own engine latch; the fence is what makes both paths behave.
        guard !isExiting else { return }
        desiredPlaying = playing
        isPlaying = playing
        transportTask?.cancel()
        transportTask = Task {
            // Re-read the engine at execution time: a pending command after
            // stop() must no-op, not poke a torn-down engine.
            guard !Task.isCancelled, let engine else { return }
            if playing { await engine.play() } else { await engine.pause() }
        }
    }

    private let deviceProfileBuilder: DeviceProfileBuilder
    private let playbackInfo: any PlaybackReporting
    private let resolve: ResolveCall
    private let engineFactory: @MainActor @Sendable (PlaybackEngineID, _ vlcLibraryOptions: [String]?) -> any PlaybackEngine
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
    /// The stream index the live `subtitleFetchTask` FETCH belongs to; nil once
    /// its install lands (or when the slot holds a same-track style rebuild).
    /// Guards the rebuild path: cancelling another track's in-flight fetch to
    /// rebuild from the INSTALLED payload would reinstall the old track under
    /// the new selection, and nothing would ever fetch the picked one.
    private var sidecarFetchStreamIndex: Int?
    /// Last appearance pushed by the overlay (`applySubtitleAppearance`) — replayed
    /// onto every freshly loaded CONVERTED renderer so a track switch keeps the
    /// user's style. Its fontScale remaps the tuned per-device size onto the
    /// synthesized script's base, which only means anything for a script we wrote.
    private var convertedSubtitleAppearance: SubtitleStyleOverride?
    /// The current sidecar's raw payload, kept so a font-design change can
    /// REBUILD the renderer: the CJK `\fn` tags and font plan are baked at load
    /// against the style family, so a new family needs a fresh load, not a
    /// style push.
    private var sidecarPayload: (data: Data, format: SubtitleSourceFormat, languageCode: String?)?
    /// The family the current renderer was built around.
    private var sidecarRendererFamily: String?
    /// Identity of one fetched sidecar. The media source is part of it because a
    /// transcode reload re-resolves the SAME source (cache still valid) while an
    /// episode change resolves a different one (stream indices mean something else).
    private struct SidecarKey: Hashable {
        let mediaSourceID: String?
        let streamIndex: Int
    }
    /// Session cache of fetched sidecar bytes. The expensive part of a first pick
    /// is the server extracting an embedded stream through ffmpeg; re-selecting a
    /// track must never pay that twice. Dropped with the rest of the session state.
    private var sidecarCache: [SidecarKey: (data: Data, format: SubtitleSourceFormat)] = [:]
    private func sidecarKey(streamIndex: Int) -> SidecarKey {
        SidecarKey(mediaSourceID: resolved?.mediaSourceID, streamIndex: streamIndex)
    }

    /// Whether picking `streamIndex` costs a fetch. The loading affordance reads this so
    /// a re-pick of an already-fetched track doesn't flash a spinner for a parse.
    private func sidecarIsCached(streamIndex: Int) -> Bool {
        sidecarCache[sidecarKey(streamIndex: streamIndex)] != nil
    }

    /// Serializes renderer style pushes: rapid preference edits must land on the actor
    /// in submission order or the renderer can finish on a stale style (the same
    /// discipline as `SubtitlePreferences.writeChain`).
    private var stylePushChain: Task<Void, Never>?
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
    /// SMB path populates it from the filename-matched sibling resolver before
    /// loading the engine. Both paths produce text-subtitle URLs (ASS/SSA/SRT/VTT)
    /// that `loadSidecarSubtitle` fetches into the client renderer.
    private var subtitleURLs: [Int: URL] = [:]
    /// Synthetic external subtitle tracks for the SMB path (`resolved` is nil there, so
    /// the Jellyfin `externalSubtitleTracks(from: resolved)` machinery can't build them).
    /// Populated in `start(smbItem:)` and re-appended to the engine's inventory on every
    /// `.ready` beat — the engine reports only EMBEDDED tracks, so without this the sidecar
    /// subs would be dropped the moment the engine's inventory lands.
    private var smbExternalSubtitleTracks: [SubtitleTrack] = []
    /// Server subtitle stream index → the id of the published menu row that renders it.
    /// Written with the menu in the `.ready` inventory beat; the only reader is the
    /// server-preferred default, which is expressed in STREAM indices while the rows are
    /// keyed by renderer. Empty on SMB/local and on the transcode path.
    private var subtitleRowIDsByStream: [Int: TrackID] = [:]
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
    /// A scrub/seek commit in flight: `currentPosition` reads the committed target (or the
    /// engine's own forward projection off it), not the engine's stale clock, until the engine
    /// reports an OBSERVED one. See `SeekHold` and `publish(position:provenance:)`. Nil
    /// whenever no seek is outstanding.
    ///
    /// `private(set)` rather than private for the paths that DROP it — an abandoned re-anchor,
    /// a failed phase, the `handle` watchdog. Every one of those is invisible from the
    /// published positions (a hold and no hold treat each provenance identically; only the
    /// window's END differs), so a test that cannot read it can only assert the defect one
    /// window later, if at all.
    private(set) var seekHold: SeekHold? {
        didSet {
            // The flight is the hold's meaning, so it cannot outlive it: every path that ends
            // a hold — the engine landing, a failed phase, an abandoned re-anchor, the
            // watchdog, `stop()` — ends the flight too, and a rule the property enforces
            // cannot be forgotten by the next one. A PREVIEW has no hold to end (the finger is
            // still down, nothing has been dispatched), so it is left alone; `beginExit()`
            // clears that one explicitly.
            if seekHold == nil, flight?.stage != .previewing { flight = nil }
        }
    }

    /// The one seek in flight — gesture, commit and landing — or nil when the bar is settled.
    /// See `SeekFlight`. Every transition is a method below; nothing else writes it.
    private(set) var flight: SeekFlight?
    /// Monotonic flight ids. Never reset: identity has to survive a re-anchor, a track switch
    /// and a `retry()` within one view model, or the bar could key an animation on a number it
    /// has already used.
    private var lastFlightID: UInt64 = 0
    private let nowPlaying: any NowPlayingUpdating
    private var itemTitle: String = ""
    /// HUD-only episode number prepended to `title` (e.g. `"2. <name>"`); nil for
    /// movies and SMB. Reset on every `start*` so an episode→movie swap clears it.
    private var episodeNumber: Int?

    // Transcode track switching: the server bakes one audio + only text subs
    // into a transcode, so switching tracks means re-resolving the stream around
    // a different source index. We keep the item + the current indices to rebuild.
    private var playingItem: ItemDetail?

    /// The playing item's artwork hue, once it has been derived — the colour the scrub bar
    /// paints its provisional elements in (see `PlayerViewModel.scrubAccent`). Nil is the
    /// answer for the whole first second of every session, for artwork with no usable colour,
    /// for SMB (no `ItemDetail`, no image ref), and for any failure along the way; nil means
    /// the bar stays its monochrome white, which is the pre-accent look.
    private(set) var accentHSB: AccentHSB?
    /// The one-shot derivation, held only so a new item (or `stop()`) can cancel a fetch that
    /// is still in flight and can't be allowed to paint the next item's bar.
    private var accentTask: Task<Void, Never>?

    /// The id requested via `start(itemID:)`, kept so `retry()` can re-fetch when
    /// the original failure was the detail fetch itself (no `playingItem` yet).
    private var pendingItemID: ItemID?
    /// The restart intent ("Play from Beginning") of the CURRENT/most recent
    /// `start(itemID:)`/`start(item:)` call — kept so `retry()` replays the same
    /// intent instead of silently falling back to resume-from-saved-position on
    /// a failed restart. Set at the top of both entry points; reset with the rest
    /// of the per-session state in `stop()`.
    private var pendingFromBeginning = false
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
    /// True once an out-of-buffer transcode seek went IN-STREAM — allowed only while no
    /// sidecar subtitle renders. The server restarted ffmpeg under the item's established
    /// timeline mapping, so the mapping may have shifted vs the frames (the 2026-07-17
    /// desync class); harmless while nothing reads the player clock absolutely, but a
    /// sidecar subtitle activated on a dirty timeline must re-anchor FIRST (see
    /// `selectSubtitleTrack`). Cleared whenever a fresh AVPlayerItem re-derives the
    /// mapping (`beginPlayback`) and on session reset.
    private var transcodeTimelineDirty = false

    /// What the live transcode job is ACTUALLY doing to the video (copy/remux vs
    /// re-encode) — the copy-vs-reencode signal `PlaybackInfo` can't give (the server
    /// reports `Transcode` for stream-copy jobs too; only the running session's
    /// `TranscodingInfo` distinguishes them, once ffmpeg has started). Nil until the
    /// probe lands (and on direct-play / SMB, which never probe; and in Release,
    /// where the probe never arms). DEBUG-display only — it feeds the delivery debug
    /// row. The seek gate deliberately IGNORES it: every out-of-buffer transcode
    /// seek re-anchors regardless of delivery (see `seek(to:)`); re-adding an
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
    private var deliveryProbeTask: Task<Void, Never>?

    /// Set once per SMB session on its first `.playing` beat; gates `scheduleThumbnailBackfill()`
    /// so a resume-from-pause or post-stall `.playing` beat never schedules a second backfill task.
    private var didScheduleThumbnailBackfill = false
    /// Pending low-priority SMB thumbnail backfill — waits past startup churn, then grabs one
    /// frame from the live engine. Cancelled on session teardown (`stop()` / deinit) so a
    /// dismissed player never pays for a capture that will never be stored.
    private var thumbnailBackfillTask: Task<Void, Never>?

    /// The resolve surface, narrowed so the integration test can inject a stub
    /// without standing up a full PlaybackInfoService. Mirrors
    /// PlaybackInfoService.resolve(item:capabilities:startTime:selection:).
    /// The selection is nil on first play (server default) and carries the user's
    /// explicit picks when a track is switched on the transcode path.
    typealias ResolveCall = @Sendable (ItemID, DeviceCapabilities, CMTime?, StreamSelection?) async throws -> ResolvedPlayback

    /// Deadline for the re-resolve inside an engine-reusing reload (re-anchor / track
    /// switch). That span shows the "Buffering" scrim with NO watchdog armed yet —
    /// `LoadWatchdog`/`StallWatchdog` only arm from `engine.play()` — so an unbounded
    /// resolve left the scrim up forever (tvOS field report, 2026-07-20). Injectable
    /// so tests can force the timeout without waiting wall-clock seconds.
    private let reloadResolveDeadline: Duration

    /// SMB-only thumbnail backfill sink: `(duration, engine.captureFramePerformsIO, captureFrame)
    /// → Void`. Default no-op so the Jellyfin construction site (and every test fixture) compiles
    /// unchanged; the SMB `PlayerView` branch wires it to `MediaArtworkProvider.backfillThumbnail`,
    /// which uses the `Bool` to skip an I/O-issuing capture on a non-LAN link. The duration is
    /// sampled at call time (~8s into playback), not at schedule time.
    private let backfillThumbnail: @Sendable (Duration?, Bool, @escaping @Sendable () async -> Data?) async -> Void

    /// Delay before the SMB thumbnail backfill grabs its frame — see `scheduleThumbnailBackfill()`.
    /// Injectable so tests don't wait wall-clock seconds for it to fire.
    private let backfillDelay: Duration

    /// The clock `SeekHold` is armed and judged against — `commitScrubSeek` stamps `armedAt`
    /// with it and `publish` passes it as `now`. Injectable for one reason: `SeekHold.watchdog`
    /// is 20 s, and the branch it guards (an engine that stops observing forever) is otherwise
    /// only reachable by a test that waits 20 wall-clock seconds. One closure for both reads so
    /// they can never disagree about what "now" is.
    private let seekHoldNow: @Sendable () -> ContinuousClock.Instant

    /// The playing item's artwork bytes, for the scrub bar's accent hue. A closure because the
    /// image lives behind a session-scoped image pipeline (auth header, shared disk cache) the
    /// view model has no business knowing about; the default answers nil, which is the white
    /// bar. Bytes rather than a decoded image on purpose: `Data` crosses to the extraction's
    /// off-main task without an isolation argument, and the decode is part of the work we are
    /// moving off the main thread anyway.
    private let fetchArtwork: @Sendable (ItemDetail) async -> Data?

    /// The user's subtitle appearance, read at asset-construction time. A closure rather
    /// than a value: `SubtitlePreferences` loads its persisted style asynchronously, so a
    /// value captured when the view model was built could be the pre-load default.
    /// Sampled ONCE per session — `:ssa-fontsdir` is a media option read when libvlc builds
    /// the decoder, and the `--freetype-font`/`--freetype-*` look is an instance argument
    /// fixed when the player's library is built. Neither can change under a live player.
    private let subtitleStyle: @MainActor () -> SubtitleStyle

    /// The player's measured surface, for the one asset field that needs a size at load
    /// (`EngineSubtitleTextStyle.relativeFontSize`). Nil until the player's geometry has
    /// landed — which normally beats the resolve it races, so the fallback is a cold-start
    /// guard, not the usual path.
    private let playerSurface: @MainActor () -> CGSize?

    /// The subtitle typeface in the font bundle's own vocabulary — the one both
    /// engine-facing font knobs are expressed in.
    private var bundleFontDesign: SubtitleFontBundle.Design { subtitleStyle().fontDesign.bundleDesign }

    /// The user's style as VLC's freetype renderer takes it, sized against the live
    /// surface. Rides every asset so an embedded SRT the ENGINE draws matches the cue
    /// the client renderer draws for an external one.
    private var engineSubtitleTextStyle: EngineSubtitleTextStyle {
        let style = subtitleStyle()
        let surface = playerSurface() ?? PlayerMetrics.defaultSurface
        return EngineSubtitleTextStyle(
            style: style, relativeFontSize: style.freetypeRelativeFontSize(surface: surface)
        )
    }

    init(
        deviceProfileBuilder: DeviceProfileBuilder,
        playbackInfo: any PlaybackReporting,
        resolve: @escaping ResolveCall,
        engineFactory: @escaping @MainActor @Sendable (PlaybackEngineID, _ vlcLibraryOptions: [String]?) -> any PlaybackEngine,
        audioSession: any AudioSessionControlling,
        nowPlaying: any NowPlayingUpdating = NowPlayingController(),
        fetchDetail: @escaping @Sendable (ItemID) async throws -> ItemDetail = { _ in
            throw AppError.playback(.unsupportedFormat)
        },
        subtitleFetch: @escaping @Sendable (URL) async -> Data? = { url in
            // URLSession does not throw on HTTP 4xx/5xx — it returns the error
            // body. Without this guard a server-side conversion failure hands
            // back HTML/JSON "subtitles" and the ass→VTT fallback never fires.
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  !data.isEmpty,
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return data
        },
        rememberTrackSelection: @escaping @Sendable (TrackSelectionUpdate) async -> Void = { _ in },
        fetchSegments: @escaping @Sendable (ItemID) async -> [MediaSegment] = { _ in [] },
        fetchAdjacent: @escaping @Sendable (ItemID, ItemID) async -> AdjacentEpisodes = { _, _ in .none },
        keepaliveInterval: Duration = .seconds(30),
        fetchDelivery: @escaping @Sendable (String) async -> TranscodeDelivery? = { _ in nil },
        deliveryProbeSchedule: [Duration] = [.seconds(2), .seconds(5)],
        reloadResolveDeadline: Duration = .seconds(15),
        smbResumeStore: SMBResumeStore = .shared,
        backfillThumbnail: @escaping @Sendable (Duration?, Bool, @escaping @Sendable () async -> Data?) async -> Void = { _, _, _ in },
        backfillDelay: Duration = .seconds(8),
        subtitleStyle: @escaping @MainActor () -> SubtitleStyle = { .standard },
        playerSurface: @escaping @MainActor () -> CGSize? = { nil },
        seekHoldNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        fetchArtwork: @escaping @Sendable (ItemDetail) async -> Data? = { _ in nil }
    ) {
        self.deviceProfileBuilder = deviceProfileBuilder
        self.playbackInfo = playbackInfo
        self.resolve = resolve
        self.engineFactory = engineFactory
        self.audioSession = audioSession
        self.nowPlaying = nowPlaying
        self.fetchDetail = fetchDetail
        self.subtitleFetch = subtitleFetch
        self.rememberTrackSelection = rememberTrackSelection
        self.fetchSegments = fetchSegments
        self.fetchAdjacent = fetchAdjacent
        self.keepaliveInterval = keepaliveInterval
        self.fetchDelivery = fetchDelivery
        self.deliveryProbeSchedule = deliveryProbeSchedule
        self.reloadResolveDeadline = reloadResolveDeadline
        self.smbResumeStore = smbResumeStore
        self.backfillThumbnail = backfillThumbnail
        self.backfillDelay = backfillDelay
        self.subtitleStyle = subtitleStyle
        self.playerSurface = playerSurface
        self.seekHoldNow = seekHoldNow
        self.fetchArtwork = fetchArtwork
    }

    isolated deinit {
        // Match the JellyfinSearchViewModel teardown discipline: the consumer
        // Task is stored on the VM, so cancel it on the MainActor before
        // release. The engine's stream finishes on teardown() (called from
        // stop()); cancelling here makes teardown immediate if stop() was
        // never reached.
        stateTask?.cancel()
        subtitleFetchTask?.cancel()
        stylePushChain?.cancel()
        stallDebounceTask?.cancel()
        keepaliveTask?.cancel()
        deliveryProbeTask?.cancel()
        thumbnailBackfillTask?.cancel()
        segmentsTask?.cancel()
        accentTask?.cancel()
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
        // Same commit path as the chapter jump: transport-preserving (an out-of-buffer
        // re-anchor's reload force-resumes) and it arms the seek hold, so the bar shows
        // the skip destination instead of the intro's clock behind the reload scrim.
        await seekPreservingTransport(to: CMTime(seconds: segment.endSeconds, preferredTimescale: 600))
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
        // A delay nudge belongs to the item it was tuned against — the next episode
        // has its own muxing and starts level. (A retry of the SAME item goes through
        // `resetForReplay` directly and keeps it, like `playbackRate`.)
        subtitleDelayMs = 0
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

    /// Derives the scrub bar's accent from the item's artwork, once per item, in the background.
    /// Reset to nil FIRST so an episode→episode swap can never show the previous poster's hue
    /// on the new item's bar, not even for the beat before the new fetch answers.
    ///
    /// Nothing here is allowed to matter: the fetch is best-effort, the decode runs off the main
    /// actor (a poster decode has no business on the main thread while a stream is opening), and
    /// every failure — no ref, no bytes, no colour in the artwork — leaves the bar white. It is
    /// deliberately NOT awaited anywhere in the start path.
    ///
    /// The decode is a `nonisolated` call, not a nested `Task.detached`: awaiting a detached
    /// task's `.value` is not a cancellation point, so a nested one outlived the item it was
    /// decoding for. A plain call inherits this task's cancellation and is one hop cheaper.
    private func loadAccent(for item: ItemDetail) {
        accentTask?.cancel()
        accentHSB = nil
        accentTask = Task(priority: .utility) { [weak self, fetchArtwork] in
            guard let data = await fetchArtwork(item), !Task.isCancelled else { return }
            let accent = await Self.extractAccent(from: data)
            guard !Task.isCancelled else { return }
            self?.accentHSB = accent
        }
    }

    /// The decode + vote, off the main actor. `nonisolated` is the whole point: the view model is
    /// `@MainActor`, and this is the one step that must not run there.
    private nonisolated static func extractAccent(from data: Data) async -> AccentHSB? {
        ArtworkAccent.accent(fromImageData: data)
    }

    /// Direct-play entry: fetch the item's detail, then play. The frosted reload
    /// cover stays up through the fetch (phase == .loading), so there's no separate
    /// spinner. Used when a screen has only the item id (an episode tapped in Home /
    /// Search / a library / a season list) — no detail screen in between.
    /// `fromBeginning` — see `start(item:fromBeginning:)`; threaded through once the
    /// detail fetch lands.
    func start(itemID: ItemID, fromBeginning: Bool = false) async {
        phase = .loading
        pendingItemID = itemID
        pendingFromBeginning = fromBeginning
        do {
            let detail = try await fetchDetail(itemID)
            try checkStillActive()
            await start(item: detail, fromBeginning: fromBeginning)
        } catch is CancellationError {
            // Exit raced the detail fetch — the view is gone; nothing to surface.
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            Log.playback.error("item detail fetch failed: \(error.networkDiagnostic)")
            phase = .failed(.unexpected("couldn't load item", underlying: AnySendableError(error)))
        }
    }

    /// `fromBeginning`: the context menu's explicit "Play from Beginning" — true
    /// starts at 0:00 regardless of any saved resume position. Defaulted so every
    /// existing tap-to-resume call site is unaffected. It threads into `startTime`,
    /// which every method resumes by SEEKING client-side on `.ready` (see
    /// `makeAsset`), so a restart is simply a nil start time.
    func start(item: ItemDetail, fromBeginning: Bool = false) async {
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        phase = .loading
        didApplyPreferredTracks = false
        pendingFromBeginning = fromBeginning
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
        loadAccent(for: item)

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
            // fromBeginning short-circuits straight to nil — identical to the "no
            // saved position" case below, so an unwatched item behaves exactly the
            // same under either flag value (nothing to guard: they're the same call).
            let resumeTime = fromBeginning
                ? nil
                : ResumePolicy.resumeStartTime(positionTicks: positionTicks, runtime: runtime)
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
                // The bundled Noto faces, for VLC's own text renderers. SMB
                // embedded tracks have no extraction endpoint, so the engine keeps
                // rendering them — `engineSubtitlesDisabled` stays false and the
                // per-pick deselect in `activateSidecarSubtitle` handles sidecars.
                subtitleFontsDirectory: VLCSubtitleFonts.directory(for: bundleFontDesign),
                subtitleFontFamily: VLCSubtitleFonts.freetypeFamily(for: bundleFontDesign),
                subtitleTextStyle: engineSubtitleTextStyle,
                engineSubtitlesDisabled: false,
                vlcOptions: smbItem.vlcOptions,
                vlcLibraryOptions: smbItem.vlcLibraryOptions
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
        // Session-scoped one-shot: a fresh SMB session (retry, next file) must not inherit a
        // stale "already scheduled" flag from the previous one — and the previous session's
        // still-sleeping backfill task must not wake up against the new session either.
        didScheduleThumbnailBackfill = false
        thumbnailBackfillTask?.cancel()
        thumbnailBackfillTask = nil
        await session.resumeSaveTask?.value
    }

    /// Best-effort SMB thumbnail backfill: waits past playback startup churn (~8s — first frames
    /// are often black / fade-in, and the engine is still settling decode + buffer), then — if the
    /// session is still the active one and no thumbnail already exists for this file — grabs a
    /// frame from the live engine and stores it into the SMB thumbnail cache, healing a
    /// previously-failed or never-attempted thumbnail just by being watched. Low priority: must
    /// never affect playback. Cancelled on session teardown (`stop()`, `tearDownEngine()`, deinit).
    private func scheduleThumbnailBackfill() {
        thumbnailBackfillTask?.cancel()
        // The delay is read HERE, and `self` is only reached after it: holding a strong `self`
        // across an 8s sleep pins the whole view model for the length of the delay and puts the
        // `isolated deinit`'s cancel out of reach. Same shape as `stallDebounceTask` /
        // `deliveryProbeTask`.
        let delay = backfillDelay
        thumbnailBackfillTask = Task(priority: .low) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard let session = self.smbSession, let engine = self.engine else { return }
            // Duration sampled NOW (not at schedule time): playback has progressed ~8s, and
            // VLC may have only just resolved a real length. Same gate as the resume store
            // (`saveSMBResumeThrottled`): the duration only rides along when it's both real
            // (`hasKnownDuration`) AND TRUSTED (`session.hasTrustworthyDuration`) — an
            // incomplete file can play with a NUMERIC but ESTIMATED length
            // (VLCKitEngine's fileSize×time/readBytes guess), and that must never ride along
            // as a bogus sidecar.
            let duration: Duration? = (self.hasKnownDuration && session.hasTrustworthyDuration)
                ? .seconds(CMTimeGetSeconds(self.currentDuration))
                : nil
            await self.backfillThumbnail(duration, engine.captureFramePerformsIO) { [weak engine] in
                await engine?.captureFrame()
            }
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
        reusingEngine: Bool = false,
        superseding: PlaybackSessionID? = nil
    ) async throws {
        try checkStillActive()
        let caps = await deviceProfileBuilder.build()
        let selection = streamSelection(
            for: item,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex
        )
        let resolved: ResolvedPlayback
        if reusingEngine {
            // A reload holds the "Buffering" scrim through this call with no watchdog
            // armed yet (see `reloadResolveDeadline`) — bound it, so a wedged
            // negotiation becomes the ordinary fallback (old stream resumes, the
            // failure is loud, the next scrub retries) instead of a stuck scrim.
            let resolveStart = ContinuousClock.now
            resolved = try await Self.withDeadline(reloadResolveDeadline) { [resolve] in
                try await resolve(item.id, caps, startTime, selection)
            }
            // The second leg of the boundary trail (see `performTranscodeReload`): how long the
            // server took to hand back a replacement stream, and which play session it opened.
            Log.playback.info(
                """
                reload resolve: \(Self.millis(since: resolveStart), privacy: .public)ms \
                playSession=\(resolved.playSessionID, privacy: .public)
                """
            )
        } else {
            resolved = try await resolve(item.id, caps, startTime, selection)
        }
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

        let asset = makeAsset(from: resolved)
        try await loadAndPlay(asset, reusingEngine: reusingEngine, superseding: superseding)
        // The engine now plays a FRESH AVPlayerItem whose timeline mapping derives from
        // this session's own segments — any prior in-stream restart shift is laundered.
        transcodeTimelineDirty = false
    }

    /// Describes the explicit track picks for a re-resolve, or nil to let the server
    /// choose (first play, and an episode swap — which arrives with no picks and a
    /// `resolved` still pointing at the previous episode).
    ///
    /// The media source id comes from the session being replaced: the server only
    /// honors stream indices that are sent alongside the source they index into, so
    /// a selection built without one would be dropped server-side. That also means a
    /// selection is only ever valid for the SAME item, hence the id check.
    private func streamSelection(
        for item: ItemDetail,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) -> StreamSelection? {
        guard audioStreamIndex != nil || subtitleStreamIndex != nil,
              let current = resolved, current.itemID == item.id.rawValue
        else { return nil }
        // An image subtitle can only arrive painted into the video, which rules out a
        // stream copy — the selection carries that so the request can say so.
        let burnsIn = subtitleStreamIndex.map { index in
            current.mediaStreams.contains {
                $0.kind == .subtitle && $0.index == index && $0.isImageSubtitle
            }
        } ?? false
        return StreamSelection(
            mediaSourceID: current.mediaSourceID,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            burnsInSubtitle: burnsIn
        )
    }

    /// Whole milliseconds since `start`. The reload's trace is a sequence of durations —
    /// encode kill, re-resolve, engine load — and a device log answers "which step was slow"
    /// only if each one is measured the same way.
    private static func millis(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    /// Races `operation` against a wall-clock deadline; a miss throws
    /// `.network(.timedOut)` (the standard "server took too long" surface) and
    /// cancels the operation. The bound is COOPERATIVE: the task group awaits the
    /// cancelled loser on exit, so an operation that ignores cancellation delays the
    /// timeout until it unblocks — fine for the URLSession-backed resolve (cancellation-
    /// aware end to end), but don't reach for this around uncancellable work.
    private static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw AppError.network(URLError(.timedOut))
            }
            // First child to finish wins — a timeout throws out of `next()`, and the
            // loser is cancelled either way.
            guard let first = try await group.next() else {
                throw AppError.network(URLError(.timedOut))
            }
            group.cancelAll()
            return first
        }
    }

    /// Select the engine for `asset`, (re)build or reuse it, load, fence, and play —
    /// the shared tail of every play path. `beginPlayback` (Jellyfin) and
    /// `start(smbItem:)` (SMB) both end here, so the engine lifecycle (subscription,
    /// Now Playing wiring, tvOS display-mode match, load-failure teardown, rate
    /// re-apply) lives in exactly one place.
    private func loadAndPlay(
        _ asset: PlayableAsset,
        reusingEngine: Bool,
        forcedEngine: PlaybackEngineID? = nil,
        superseding: PlaybackSessionID? = nil
    ) async throws {
        // Recorded up front (before the engine even attempts the load) so a reactive
        // fallback (`attemptReactiveFallback`) can rebuild this exact asset off it
        // without threading a duplicate copy through every play path.
        currentAsset = asset
        // `forcedEngine` is the reactive fallback's retry (`attemptReactiveFallback`)
        // pinning the rebuilt asset onto VLCKit — EngineSelector stays pure and never
        // sees the override. Every other call site leaves it nil and gets the ordinary
        // hint-driven routing.
        let id = forcedEngine ?? EngineSelector.select(hints: asset.hints)
        // Who owns `desiredPlaying`. Only a FRESH session — the user opening an item —
        // makes starting playback the intent to play. A reload (`reusingEngine`: the
        // scrub commit's re-anchor and the transcode track switch) and the reactive
        // AVKit->VLC reroute (`forcedEngine`) are mechanical: they resume because the
        // decoder has to be told to run, not because anyone asked. Those inherit the
        // standing intent, and the engine they come up on is commanded from it below —
        // so a lock-screen pause issued while the engine was being rebuilt survives the
        // rebuild instead of being overwritten by it.
        let isFreshSession = !reusingEngine && forcedEngine == nil

        // Reuse the live engine when a transcode track switch keeps the same engine
        // type: reloading the asset on the existing AVPlayer keeps its video layer
        // mounted, so the surface holds the last frame through the swap instead of
        // tearing down to black. A fresh play (or an engine-type change) builds a new
        // engine and wires up its state subscription + Now Playing handlers. Also
        // excluded when the new asset's libvlc INSTANCE arguments differ from the ones the
        // existing engine was built with — those are fixed at construction
        // (VLCKitEngine.init), so reusing would silently keep serving the OLD ones. Equality
        // and not mere presence: every VLC asset carries the subtitle look here now, and a
        // presence test would retire engine reuse entirely.
        //
        // Computed for the engine being BUILT, which is what makes the comparison honest:
        // the factory's AVKit branch drops these (AVFoundation draws its own subtitles), so
        // an AVKit engine is never built with them and must not be retired over them — a
        // mid-session subtitle restyle would otherwise tear down the AVPlayer, and with it
        // the held frame that transcode track switches exist to preserve.
        let libraryOptions = id == .vlcKit ? VLCKitEngine.libraryOptions(for: asset) : nil
        let engine: any PlaybackEngine
        let rebuilt: Bool
        if reusingEngine, let existing = self.engine, existing.id == id,
           libraryOptions == engineLibraryOptions {
            engine = existing
            rebuilt = false
        } else {
            rebuilt = true
            // The replacement is built BEFORE the outgoing engine is retired, and the slot
            // installs it in the same tick the old one leaves: the host view stays mounted
            // over the frozen frame, and `attachIfNeeded` re-points the drawable in place.
            // `EngineSlot.swap` cuts the outgoing audio on the spot (two decoders feeding
            // one output is the audible defect) and moves only the slow half — the
            // teardown — off this path, into a retirement `stop()` drains.
            engine = engineFactory(id, libraryOptions)
            await engineSlot.swap(to: engine)
            engineLibraryOptions = libraryOptions
            subscribe(to: engine)
            nowPlaying.configure(
                // Transport-preserving: a paused lock-screen scrub must not come back
                // playing when an out-of-buffer target re-anchors (reload force-resumes).
                onSeek: { [weak self] time in Task { await self?.seekPreservingTransport(to: time) } },
                // Route through setPlaying (not engine.play/pause directly) so a remote command
                // clears any pending scrub latch — otherwise it's swallowed and the glyph sticks.
                onPlay: { [weak self] in self?.setPlaying(true) },
                onPause: { [weak self] in self?.setPlaying(false) }
            )
        }

        do {
            // Exit can land inside the swap's audio cut. Checked here, inside the teardown
            // path, so a replacement that was installed for a player already dismissing is
            // torn down with its subscription rather than left resident until `stop()`.
            try checkStillActive()
            // The load's return value IS the boundary: from here on this is the only session
            // whose beats this view model adopts, and everything the media it replaced still
            // has in flight is stamped with a session that no longer matches.
            let loadStart = ContinuousClock.now
            let opened = try await engine.load(asset)
            // The re-anchor trail, and the only place it is emitted: a session transition is
            // the one event every silent failure in this path has in common, and it is a fact
            // about the load rather than about whatever beat happens to arrive later. A
            // re-anchor that never reloads never prints one — which is the whole point of
            // putting the line here instead of at a beat that may or may not come.
            Log.playback.info(
                """
                playback session \(superseding?.description ?? self.activeSession?.description ?? "none", privacy: .public) → \
                \(opened.description, privacy: .public) \
                origin=\(isFreshSession ? "fresh" : (reusingEngine ? "reload" : "reroute"), privacy: .public) \
                engine=\(rebuilt ? "rebuilt" : "reused", privacy: .public) \
                at=\(CMTimeGetSeconds(asset.startTime ?? .zero), format: .fixed(precision: 1), privacy: .public)s \
                load=\(Self.millis(since: loadStart), privacy: .public)ms \
                playSession=\(self.resolved?.playSessionID ?? "—", privacy: .public)
                """
            )
            activeSession = opened
            // A frozen surface at the session boundary IS the reload: `performTranscodeReload`
            // froze the outgoing frame under the cover, and only this session's first live beat
            // can take it back down.
            reloadAwaitingFirstLiveBeat = surfaceFrozen
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
        if isFreshSession { desiredPlaying = true }
        await engine.play()
        // A freshly-built engine starts at 1.0×; re-apply the chosen speed so it
        // survives an engine rebuild (track switch / first play after a speed change).
        // Guarded on identity: a reactive reroute can interleave and tear this engine
        // down while the await above was suspended, and setRate must not reach a
        // torn-down engine.
        if playbackRate != 1, self.engine === engine {
            await engine.setRate(playbackRate)
        }
        // Same shape for the subtitle delay: `load()` resets the engine's copy (it is
        // input-scoped and belongs to the media that was just replaced), so the intent
        // this view model holds for the item has to be re-pushed onto the fresh input.
        if subtitleDelayMs != 0, self.engine === engine {
            await engine.setSubtitleDelay(milliseconds: subtitleDelayMs)
        }
        // The rebuilt engine is commanded from the standing intent, not from the load's
        // own mechanical `play()`: a pause issued while the engine was being replaced
        // (lock screen, Now Playing, the transport button) landed on the OUTGOING engine,
        // and without this the replacement comes up playing against it.
        // Rebuilds only: an engine-REUSING reload is the re-anchor, whose paused-user
        // re-pause belongs to `commitScrubSeek`, which sequences it against the seek.
        if rebuilt, !desiredPlaying, self.engine === engine {
            await engine.pause()
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
        keepaliveTask?.cancel()
        keepaliveTask = nil
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        // The backfill is a ONE-SHOT per SMB session, armed on the first `.playing` beat and
        // sitting on a multi-second delay. A reactive engine rebuild (AVKit → VLC) mid-delay would
        // otherwise let it fire against an engine being torn down and burn the session's only
        // attempt; cancelling and re-arming lets the rebuilt engine's next `.playing` beat schedule
        // a clean one. The SMB session itself survives a rebuild, so the flag has to be reset here
        // too (`clearSMBSession` only runs when the session really ends).
        thumbnailBackfillTask?.cancel()
        thumbnailBackfillTask = nil
        didScheduleThumbnailBackfill = false
        transcodeDelivery = nil
        stateTask?.cancel()
        stateTask = nil
        // No engine, no session: a beat that survives the cancellation below belongs to media
        // this view model no longer has any surface for.
        activeSession = nil
        await engineSlot.drain()
        // A load failure tears the bridge down with the engine: nothing consumes the stream, so
        // the orphaned listener + its SMB connection must not outlive the failed load.
        await tearDownSMBBridge()
        await stopEncodingIfNeeded()
    }

    /// THE exit hand-off, and the only urgent part of leaving: everything else rides the
    /// close animation out (see `PlayerView.exitPlayer` / `stop()` on `onDisappear`).
    ///
    /// Synchronous so it fences before the async `stop()` gets a MainActor turn: an
    /// in-flight `start()` resuming in between can't slip past a checkpoint and build/play
    /// an engine for a player that's already going away. Then, in order: hold the last
    /// frame (the surface freeze survives the engine stopping under it, so the card slides
    /// out on a frame instead of black), and end audio on the spot. `endAudio()`, not
    /// `silence()`, because VLC's silence is a decode-side gain that leaves the ~1-2s
    /// already queued in the audio output playing for the whole dismissal. The
    /// engine call is unstructured on purpose: no caller's cancellation may cut the audio
    /// kill short.
    ///
    /// Idempotent, because the close button fences here AND the presenter fences again on
    /// `dismiss()`, and a session only ends once.
    func beginExit() {
        guard !isExiting else { return }
        isExiting = true
        freezeVideoSurface()
        // The seek is over too: `seek(to:)` and `commitScrubSeek` both fence on `isExiting`, so
        // nothing can land this flight any more — and the surfaces stay mounted for the whole
        // slide-out, which without this carries a scrub bar and a timestamp bubble out of the
        // screen with them. (`stop()` clears it as well, but that runs on `onDisappear`, at the
        // END of the dismissal.)
        seekHold = nil
        flight = nil
        // A transport command armed just before the fence is still pending its hop to the
        // engine; `setPlaying`'s guard only covers commands that arrive after. The task
        // re-checks `Task.isCancelled` before it touches the engine, so cancelling here
        // is what stops an in-flight play from resuming audio into the dismissal.
        transportTask?.cancel()
        transportTask = nil
        let engine = engine
        Task { await engine?.endAudio() }
    }

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
        activeSession = nil   // the session ends here; nothing published from now on is ours
        // Closes the retry()/resetForReplay window where a pending reactive-fallback
        // hop outlives its session: without this, a hop scheduled just before a
        // restart could build a VLC engine for the NEW session's state.
        reactiveFallbackTask?.cancel()
        reactiveFallbackTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        transportTask?.cancel()
        transportTask = nil
        // The same drain a rebuild's retirement goes through: the reference is dropped
        // here, so nothing that re-reads `engine` can poke one that is winding down, and
        // the await covers every teardown this session started — including one a track
        // switch left running.
        await engineSlot.drain()
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
        playingItem = nil
        accentTask?.cancel()
        accentTask = nil
        accentHSB = nil
        pendingItemID = nil
        pendingFromBeginning = false
        smbResolve = nil
        currentAudioStreamIndex = nil
        currentSubtitleStreamIndex = nil
        // A re-anchor in flight is abandoned by reloadTranscode's exit fence; clear its
        // state too so a retry()/replay can't inherit a stale target or a stuck flag.
        pendingReanchorTarget = nil
        isReanchoring = false
        transcodeTimelineDirty = false
        // The held frame is deliberately NOT released here: `stop()` always runs with the
        // exit fence armed, and the exit freeze is what the card slides out on. The one
        // caller that comes back (`resetForReplay`) releases it itself, after disarming
        // the fence.
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        thumbnailBackfillTask?.cancel()
        thumbnailBackfillTask = nil
        transcodeDelivery = nil
        availableAudioTracks = []
        availableSubtitleTracks = []
        subtitleRowIDsByStream = [:]
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        trackSwitchFailure = nil
        clearSidecarSubtitle()
        sidecarCache = [:]
        subtitleURLs = [:]
        smbExternalSubtitleTracks = []
        currentPosition = .zero
        // The session is over, so any outstanding scrub target is too — a `retry()`/
        // `resetForReplay` restart must publish the NEW stream's beats, not a dead
        // seek's destination. (Deliberately NOT cleared in the transcode re-anchor
        // reload: that window is exactly what the hold exists to cover.)
        seekHold = nil
        flight = nil
        currentDuration = .zero
        chapterFractions = []
        bufferedTo = nil
        segmentsTask?.cancel()
        segmentsTask = nil
        segments = []
        adjacentEpisodes = .none
        clearStall()
        isPlaying = false
        desiredPlaying = false
        currentAsset = nil
        didReactivelyReroute = false
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
    /// of the schedule gives up silently — the row just reads "no delivery info".
    /// Direct play has no job to probe. Clears any stale delivery up front so the
    /// window (and a re-probe after a track switch, where burn-in can flip the answer)
    /// reads "probing…" until the fresh result lands. DEBUG-only: since the seek gate
    /// stopped reading delivery, the `#if DEBUG` `DebugInfoOverlay` row is the sole
    /// consumer — a Release build must not spend per-session network fetches on it.
    private func startDeliveryProbe(for resolved: ResolvedPlayback) {
        #if DEBUG
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
        #endif
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
        // Captured before resetForReplay() clears it (same pattern as item/id above) —
        // a retry after a failed restart must stay a restart, not quietly resume.
        let fromBeginning = pendingFromBeginning
        await resetForReplay()
        if let smb { await start(resolvingSMB: smb) }
        else if let item { await start(item: item, fromBeginning: fromBeginning) }
        else if let id { await start(itemID: id, fromBeginning: fromBeginning) }
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
        // Release any held frame THROUGH the action, not by clearing the flag alone: on
        // an in-place retry the host UIView survives, and a flag-only reset would strand
        // the pinned snapshot over the replayed video (the beat-side unfreeze guards on
        // the flag and would no-op forever). If the host is already gone the action's
        // weak view makes this a no-op. AFTER the fence is disarmed, since the fence is
        // what keeps `stop()` from doing this on a real exit.
        unfreezeVideoSurface()
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
        // The engine has no decoder for this track's codec — picking it would play
        // silence. The menu already shows it as unavailable; this is the choke point
        // every other caller (remote commands, the playback lab) goes through, so the
        // rule lives here too. Nothing to record: the user's real selection is unchanged.
        guard !track.isUnsupported else { return }
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
            case .fellBack:
                // Playback resumed on the previous track: restore the checkmark and
                // surface the failure scrim (retry / keep current track).
                selectedAudioTrack = previous
                trackSwitchFailure = TrackSwitchFailure(
                    requested: .audio(track),
                    fallback: previous.map(TrackPick.audio)
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

    /// Show the loading affordance for a pick that is about to be made.
    ///
    /// **Synchronous, and separate from `selectSubtitleTrack` on purpose.** The menu
    /// dismisses on the tap's own turn, and every path from the tap to the fetch suspends
    /// first (`engine.setSubtitleTrack(nil)` at minimum), so a state written inside the
    /// async pick lands after the panel showing it is gone. The view calls this before it
    /// closes the menu; the fetch itself re-asserts the same slot once it starts
    /// (`loadSidecarSubtitle`), which is all a programmatic pick needs. Idempotent.
    ///
    /// Nothing to show for Off, for a burn-in (a re-resolve, with its own scrim), or for
    /// a track already in the session cache — that pick is instant.
    func armSubtitleFetchIndicator(for track: SubtitleTrack?) {
        guard let track, !track.isBurnedIn, let index = track.id.jellyfinStreamIndex,
              !sidecarIsCached(streamIndex: index)
        else { return }
        sidecarFetchStreamIndex = index
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
            // Two states force the reload-then-activate path, and both must wait for the
            // fresh item before fetching: leaving an active burn-in (the outgoing session
            // is still burning the image in, and its subtitleURLs are stale) and a DIRTY
            // timeline (an in-stream out-of-buffer seek restarted ffmpeg under this
            // item's mapping — permitted only while no sidecar rendered, see `seek(to:)`)
            // that must be laundered BEFORE absolute-timestamp cues draw.
            if leavingBurnIn || (resolved?.method == .transcode && transcodeTimelineDirty) {
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
            // A burn-in is the one pick whose success the client can't see: the
            // subtitle lives inside the video pixels, so a server that quietly
            // declined to paint it looks exactly like one that did. Ask the fresh
            // session what it actually agreed to before claiming the pick worked.
            if let target, target.isBurnedIn, !serverBurnsInSubtitle(at: subtitleStreamIndex) {
                // Unlike the arms below, the reload DID happen — the new session was
                // built around an index it isn't burning in, so leaving it recorded
                // would make the next audio switch ask for the same dead pick. And
                // because the session is FRESH, restoring an external text track goes
                // through the full activation (incl. the mandatory engine deselect
                // that guards the double-subtitle bug), not the bare restore the
                // not-landed arms use.
                // The declined session was still negotiated FOR a burn-in — video
                // stream copy off, a full re-encode with nothing to show for it —
                // so the rollback must re-resolve too, not just restore the
                // overlay, or the wasteful session outlives the failed pick. No
                // recursion risk: the fallback is never a burn-in. The failure
                // record lands AFTER the nested reload, whose own optimistic set
                // would clear it.
                let fallback = previous.flatMap { $0.isBurnedIn ? nil : $0 }
                if let fallback, let prevIndex = fallback.id.jellyfinStreamIndex {
                    await reloadSubtitleTranscode(to: fallback, subtitleStreamIndex: prevIndex) {
                        await self.activateSidecarSubtitle(fallback, index: prevIndex)
                    }
                } else {
                    await reloadSubtitleTranscode(to: nil, subtitleStreamIndex: -1)
                }
                trackSwitchFailure = TrackSwitchFailure(
                    requested: .subtitle(target),
                    fallback: fallback.map(TrackPick.subtitle)
                )
                return
            }
            await onCompleted()
            persistTrackSelection(.subtitles(languageCode: target?.languageCode))
        case .abandoned:
            selectedSubtitleTrack = previous
            restoreSidecarSubtitle(previous)
        case .fellBack:
            selectedSubtitleTrack = previous
            restoreSidecarSubtitle(previous)
            trackSwitchFailure = TrackSwitchFailure(
                requested: .subtitle(target),
                fallback: previous.map(TrackPick.subtitle)
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
        // Drop the OUTGOING track's cues before the fetch. The menu already reads
        // the new language, and a cold embedded stream can take seconds to extract
        // server-side — leaving the old bitmaps up for that window shows one
        // language while the UI claims another.
        clearSidecarSubtitle()
        currentSubtitleStreamIndex = index
        selectedSubtitleTrack = track
        loadSidecarSubtitle(streamIndex: index, languageCode: track.languageCode)
    }

    /// Re-arms the client overlay for the track a failed/abandoned subtitle switch fell
    /// back to — every `reloadSubtitleTranscode` failure/abandon arm (a pick INTO a
    /// burn-in, or leaving one for Off/a text sub) clears the sidecar optimistically
    /// before the re-resolve; when that re-resolve doesn't land, the still-mounted
    /// previous session needs its text overlay back (a bare Off/burn-in track needs
    /// nothing — there's no sidecar to fetch either way).
    private func restoreSidecarSubtitle(_ track: SubtitleTrack?) {
        guard let track, let index = track.id.jellyfinStreamIndex, !track.isBurnedIn else { return }
        loadSidecarSubtitle(streamIndex: index, languageCode: track.languageCode)
    }

    /// Jellyfin's word for burn-in in the per-stream delivery method it reports back
    /// on every resolve. Compared case-insensitively — it's a wire enum name, not a
    /// value we control.
    private static let burnInDeliveryMethod = "encode"

    /// Whether the CURRENTLY resolved session says it is painting the subtitle at
    /// `index` into the video. This is the only client-visible proof a burn-in pick
    /// took: the server answers a request it won't honor with a perfectly normal
    /// stream that simply has no subtitle in it. Shared by the post-switch check and
    /// the debug panel, so both read the same verdict.
    func serverBurnsInSubtitle(at index: Int) -> Bool {
        guard let stream = resolved?.mediaStreams.first(where: {
            $0.kind == .subtitle && $0.index == index
        }) else { return false }
        return stream.subtitleDeliveryMethod?.lowercased() == Self.burnInDeliveryMethod
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
           // A track the engine can't decode is not a candidate — auto-selecting the
           // user's preferred language would trade the engine's working pick for silence.
           let match = availableAudioTracks.first(where: {
               !$0.isUnsupported && TrackLanguage.matches($0.languageCode, language)
           }) {
            await engine.setAudioTrack(match)
            selectedAudioTrack = match
        }

        // SUBTITLES — only when the server's mode+language logic says one should show.
        //
        // The preference is a STREAM index; the menu is keyed by RENDERER. Go through
        // the join the menu recorded (`subtitleRowIDsByStream`) rather than assuming
        // `.jellyfinStream(index)`: a PGS/VobSub stream the engine can draw carries the
        // ENGINE's id, and matching on the stream id alone silently dropped every such
        // default on the floor.
        guard let index = resolved.defaultSubtitleStreamIndex,
              let rowID = subtitleRowIDsByStream[index],
              let row = availableSubtitleTracks.first(where: { $0.id == rowID })
        else { return }
        // `!isBurnedIn` mirrors the transcode default: burn-in is opt-in, so a default
        // that can only be delivered by re-encoding the video never fires on its own.
        // An image sub the engine renders locally is NOT that — it costs nothing, so it
        // is honoured like any other.
        guard !row.isBurnedIn else { return }
        if let sidecarIndex = row.id.jellyfinStreamIndex {
            // A sidecar default is an EXPLICIT server preference, so it overrides the
            // engine's own auto-pick. VLC selects a default/forced embedded sub on its own, and the
            // `.ready` inventory seed above adopts it into `selectedSubtitleTrack`; gating this
            // branch on `selectedSubtitleTrack == nil` (as it used to) let that embedded pick win
            // the race and strand the external default while the embedded one rendered THROUGH the
            // overlay (the double-subtitle bug). `activateSidecarSubtitle` holds the engine subtitle
            // off (`setSubtitleTrack(nil)`) so only the client-drawn sidecar shows.
            await activateSidecarSubtitle(row, index: sidecarIndex)
        } else {
            await activateEngineSubtitle(row)
        }
    }

    /// The engine-rendered counterpart of `activateSidecarSubtitle`: the row's id IS the
    /// engine's track, so the pick is a plain `setSubtitleTrack`. Any client-drawn sidecar
    /// a prior selection left up has to go — two renderers would otherwise stack.
    ///
    /// Not routed through `selectSubtitleTrack`, for the same reason the sidecar path
    /// isn't: this runs from the `.ready` beat, inside the `isStartingPlayback` window
    /// that method deliberately drops user picks in.
    private func activateEngineSubtitle(_ track: SubtitleTrack) async {
        guard let engine else { return }
        await engine.setSubtitleTrack(track)
        clearSidecarSubtitle()
        selectedSubtitleTrack = track
    }

    /// Fetches the sidecar subtitle for `streamIndex` and loads it into a fresh
    /// `SubtitleRenderer`. Cancels any in-flight fetch first so a slow/stale load
    /// can't land on screen after a newer pick. Format comes from the URL extension:
    /// the Jellyfin endpoint serves originals for formats we request verbatim
    /// (ass/ssa/srt keep their authored styling and positioning), and an SMB sibling
    /// is whatever the release shipped.
    private func loadSidecarSubtitle(streamIndex: Int, languageCode: String?) {
        subtitleFetchTask?.cancel()
        guard let url = subtitleURLs[streamIndex] else {
            clearSidecarSubtitle()
            return
        }
        let key = sidecarKey(streamIndex: streamIndex)
        if let cached = sidecarCache[key] {
            sidecarFetchStreamIndex = nil
            // Already fetched this session: no round trip, and — for an EMBEDDED
            // Jellyfin stream — no second ffmpeg extraction. Skip the loading state
            // too; the only cost left is the libass parse.
            subtitleFetchTask = Task { [weak self] in
                await self?.installSubtitleRenderer(
                    data: cached.data, format: cached.format, languageCode: languageCode
                )
            }
            return
        }
        // The first request is the only one the happy path pays: the verbatim
        // ass/ssa URL is what the renderer wants, and the VTT conversion below runs
        // ONLY when it comes back empty. Re-picking never re-pays either — the
        // bytes are cached above.
        sidecarFetchStreamIndex = streamIndex
        let fetch = subtitleFetch
        let requestedFormat = SubtitleSourceFormat(sidecarExtension: url.pathExtension)
        subtitleFetchTask = Task { [weak self] in
            var data = await fetch(url)
            var format = requestedFormat
            // A verbatim ass/ssa request can fail server-side (the endpoint only has
            // writers for some formats, and an embedded SSA track extracts as .ass) —
            // degrade to the server's VTT conversion: authored styling is lost, but
            // the track still shows instead of nothing.
            if data == nil, format == .ass || format == .ssa,
               let fallback = Self.vttFallbackURL(for: url) {
                data = await fetch(fallback)
                format = .vtt
            }
            if Task.isCancelled { return }
            guard let data else {
                // The CURRENT pick failed to fetch — leaving the previous track's
                // bitmaps on screen would lie about what's selected.
                self?.clearSidecarSubtitle()
                return
            }
            self?.sidecarCache[key] = (data, format)
            await self?.installSubtitleRenderer(data: data, format: format, languageCode: languageCode)
        }
    }

    /// Same URL with the last path component's extension swapped to `vtt` — the
    /// Jellyfin sidecar endpoint's conversion fallback. The query (auth) is preserved.
    private static func vttFallbackURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path as NSString
        guard !path.pathExtension.isEmpty else { return nil }
        components.path = path.deletingPathExtension.appending(".vtt")
        return components.url
    }

    /// Builds + publishes the renderer for a fetched sidecar. A fresh renderer per
    /// load keeps track switches simple (no cross-track libass state); the overlay
    /// detects the swap via `subtitleRendererGeneration`. Undecodable data clears
    /// instead of throwing — same silent no-op the parse path always had, now logged.
    private func installSubtitleRenderer(
        data: Data,
        format: SubtitleSourceFormat,
        languageCode: String?
    ) async {
        // Built around the style's font family so the CJK plan resolves through
        // ITS cascade — serif must reach a Mincho face for Japanese lines, which
        // a sans-based plan would tag right past.
        let family = effectiveSidecarFontFamily(for: format)
        let renderer = SubtitleRenderer(defaultFontFamily: family)
        do {
            try await renderer.load(data, format: format, languageHint: languageCode)
        } catch {
            // A STALE failure must not tear down the newer pick's in-flight load —
            // `clearSidecarSubtitle` cancels `subtitleFetchTask`, which by now may
            // belong to the next selection. Same guard the success path has.
            if Task.isCancelled { return }
            Log.playback.error("sidecar subtitle load failed (\(String(describing: format))): \(error)")
            clearSidecarSubtitle()
            return
        }
        let info = SidecarSubtitleInfo(format: format, byteCount: data.count)
        await renderer.setStyleOverride(effectiveStyleOverride(for: format))
        if Task.isCancelled { return }
        subtitleRenderer = renderer
        sidecarSubtitleInfo = info
        sidecarPayload = (data, format, languageCode)
        sidecarRendererFamily = family
        sidecarFetchStreamIndex = nil
        subtitleRendererGeneration &+= 1
    }

    /// The family the sidecar renderer plans fonts around — the style override's
    /// when the format takes it, else the renderer's own default.
    private func effectiveSidecarFontFamily(for format: SubtitleSourceFormat) -> String {
        effectiveStyleOverride(for: format)?.fontFamily ?? SubtitleRenderer.standardFontFamily
    }

    private func clearSidecarSubtitle() {
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        sidecarFetchStreamIndex = nil
        subtitleRenderer = nil
        sidecarSubtitleInfo = nil
        sidecarPayload = nil
        sidecarRendererFamily = nil
        subtitleRendererGeneration &+= 1
    }

    /// The user's subtitle style, pushed by the overlay whenever preferences or the
    /// render geometry change. It reaches converted SRT/VTT only: those scripts are
    /// ours, synthesized field by field. An authored ASS/SSA track is someone else's
    /// typesetting and keeps all of it — the one thing we change, its typefaces
    /// (whose files we don't have), is already done at load inside the renderer.
    func applySubtitleAppearance(converted: SubtitleStyleOverride?) {
        convertedSubtitleAppearance = converted
        guard let renderer = subtitleRenderer, let info = sidecarSubtitleInfo else { return }
        // A font-FAMILY change can't be pushed onto a loaded track: the CJK
        // font plan and \fn tags were baked at load against the previous
        // family. Rebuild the renderer from the kept payload instead — unless
        // another track's fetch is in flight: that install reads the family at
        // its own completion, and cancelling it here would strand the newer
        // pick on the old track's payload.
        if sidecarFetchStreamIndex == nil, let payload = sidecarPayload,
           effectiveSidecarFontFamily(for: info.format) != sidecarRendererFamily {
            subtitleFetchTask?.cancel()
            subtitleFetchTask = Task { [weak self] in
                await self?.installSubtitleRenderer(
                    data: payload.data, format: payload.format,
                    languageCode: payload.languageCode
                )
            }
            return
        }
        let effective = effectiveStyleOverride(for: info.format)
        let previous = stylePushChain
        stylePushChain = Task {
            await previous?.value          // submission order → the LAST edit wins
            await renderer.setStyleOverride(effective)
        }
    }

    private func effectiveStyleOverride(for format: SubtitleSourceFormat) -> SubtitleStyleOverride? {
        format.needsConversion ? convertedSubtitleAppearance : nil
    }

    /// Native video dimensions for the renderer's storage size — what authored `\pos`
    /// coordinates and border/shadow scale are computed against. Nil (SMB, or a
    /// server that omitted dimensions) falls back to the render canvas, which is
    /// correct-aspect anyway.
    var videoStorageSize: CGSize? {
        guard let stream = resolved?.mediaStreams.first(where: { $0.kind == .video }),
              let width = stream.width, let height = stream.height,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
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
    /// and the Now Playing remote. An OUT-OF-BUFFER seek on ANY transcode re-resolves
    /// a fresh session at the target instead of seeking in-stream. An in-playlist seek
    /// makes Jellyfin kill + restart ffmpeg at the requested segment, and the restarted
    /// segments join an AVPlayerItem whose timeline mapping was established by the
    /// ORIGINAL run — any mismatch between their internal timestamps and the declared
    /// boundary shifts the playlist clock away from the frames, desyncing the
    /// absolute-timestamped sidecar cue overlay. On a RE-ENCODE the miss is structural
    /// (`-noaccurate_seek`, jellyfin#15845: fixed offset, every restarted seek). On a
    /// VIDEO-COPY remux the keyframe-aligned playlist (MKV cue extraction) makes most
    /// restarts land true, but the server's +0.5s seek pad and long-GOP keyframe gaps
    /// still miss intermittently — variable offset up to a keyframe interval, mostly on
    /// forward jumps (backward lands on already-produced segments). Device-confirmed
    /// 2026-07-17: the former `isVideoDirect` exemption shipped exactly that desync.
    /// A fresh AVPlayerItem re-derives its mapping from the new segments, so the
    /// re-anchor is always clean — "dismiss + restart fixes it", automated.
    ///
    /// In-buffer transcode seeks (segments already downloaded under the live mapping)
    /// and every direct-play / VLC / SMB seek stay in-stream.
    ///
    /// SUBS-AWARE SCOPE (2026-07-20): the shifted mapping only has ONE absolute-clock
    /// consumer — the sidecar cue overlay. Burn-ins ride the video and embedded tracks
    /// ride the stream clock, so they shift WITH the frames and stay visually synced.
    /// While no sidecar renders, an out-of-buffer seek therefore goes IN-STREAM (old
    /// scrub feel: buffer preserved, plain re-buffer instead of the scrim) and marks
    /// `transcodeTimelineDirty`; activating a sidecar later launders the timeline with
    /// one re-anchor (`selectSubtitleTrack`). With a sidecar up, only the re-anchor
    /// keeps its cues honest. Known accepted skew on a dirty timeline: reported
    /// positions/resume points can be off by up to a keyframe interval — same as the
    /// pre-re-anchor behavior.
    ///
    /// REVISIT when the server runs Jellyfin ≥ 12.0: it ships #15926 (drops
    /// `-noaccurate_seek` for full re-encodes) and #16580 (trims copied audio to the
    /// seek target), making RE-ENCODE mid-session restarts frame-accurate — those
    /// could then seek in-stream even with a sidecar up. Neither PR touches the
    /// VIDEO-COPY miss (+0.5s remux seek pad / long-GOP keyframe gaps vs the item's
    /// established mapping), so remuxes keep the sidecar-gated re-anchor. Re-verify
    /// with the 2026-07-17 witness protocol (Claude memory:
    /// subtitle-scrub-desync-history) before relaxing anything.
    /// Returns `true` when the seek RE-ANCHORED (rebuilt the transcode via
    /// `reloadTranscode`, which force-resumes playback), `false` for an in-stream
    /// `engine.seek`. `commitScrubSeek` branches on it to restore a paused scrub's
    /// pause after a force-resuming reload.
    @discardableResult
    func seek(to target: CMTime) async -> Bool {
        // Exit fence: the engine is stopped and its audio is ended for good the moment the
        // player starts leaving, but the surfaces above are still mounted for the whole
        // slide-out and a seek arriving now would re-anchor (or re-buffer) a dead session.
        guard !isExiting else { return false }
        guard let engine else { return false }
        // Only a transcode can restart ffmpeg under the item's timeline mapping;
        // direct play / VLC / SMB seek in-stream. Delivery (copy vs re-encode) does
        // NOT exempt — see the doc above.
        guard resolved?.method == .transcode else {
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
        }
        // Out of buffer, no sidecar rendering, no reload in flight: nothing reads the
        // clock absolutely, so take the in-stream seek (buffer intact, ordinary
        // re-buffer UX) and record the possibly-shifted mapping for the next sidecar
        // activation to launder. The `isSwitchingTracks` check is load-bearing: a
        // reload's OPTIMISTIC selection (e.g. a burn-in pick) can read as "no sidecar"
        // mid-flight, and an in-stream seek then would both race the dying engine and
        // mark dirty in a window where a failed switch RESTORES a text sidecar without
        // laundering. Inside that window only the re-anchor path is safe — it degrades
        // to the documented drop-don't-queue abandon.
        if !sidecarSubtitleActive && !isSwitchingTracks {
            transcodeTimelineDirty = true
            await engine.seek(to: target)
            return false
        }
        pendingReanchorTarget = target
        await drainReanchorSeeks()
        return true
    }

    /// True while the client-rendered sidecar overlay owns subtitles — the one consumer
    /// that matches ABSOLUTE cue timestamps against the player clock. (`jellyfinStream`
    /// ids are exactly the tracks `SubtitleOverlayView` draws; burn-ins carry a stream
    /// id only until the reload lands, but their pick always reloads anyway.)
    private var sidecarSubtitleActive: Bool {
        selectedSubtitleTrack.map { !$0.isBurnedIn && $0.id.jellyfinStreamIndex != nil } ?? false
    }

    /// A scrub-commit seek: the gated `seek(to:)` followed by the pre-scrub transport
    /// replay. Every touch/VoiceOver/tvOS scrub commit routes its seek through `seek(to:)`
    /// so an out-of-buffer transcode seek re-anchors instead of drifting the subtitle
    /// overlay; the touch drag additionally pauses the engine to
    /// hold the still frame, so it must replay the user's pre-scrub play state here.
    ///
    /// The wrinkle a bare `seek` can't cover: a re-anchor runs `reloadTranscode`, whose
    /// `loadAndPlay` UNCONDITIONALLY resumes — so a scrub that began while PAUSED comes
    /// back playing unless we re-pause it. An in-stream seek leaves the drag's pause in
    /// place, so it only needs the resume. `resume` is the chain-start play state
    /// (`scrubWasPlaying`); the caller owns the generation-guarded `isScrubbing` release
    /// around this call.
    /// `commitScrubSeek` with the user's CURRENT transport intent: the transport-preserving
    /// seek for every non-scrub surface (chapter list, Now Playing remote, tvOS effects),
    /// where no latch pins a pre-gesture state. Without it, a paused out-of-buffer seek comes
    /// back playing (the re-anchor's reload force-resumes); the same bug `commitScrubSeek`
    /// fixes for drags.
    ///
    /// `desiredPlaying`, not `isPlaying`: the mirror can read paused simply because a scrub or
    /// a seek fetch is in flight, and resuming off that stale read is the stuck-paused bug.
    func seekPreservingTransport(to target: CMTime) async {
        await commitScrubSeek(to: target, resume: desiredPlaying)
    }

    /// A gesture has taken the bar: the finger (or the tvOS swipe) is previewing `requested`
    /// while the picture stays where it is. Nothing is dispatched — this is the state the
    /// concrete/virtual split draws, and the state a commit converts.
    ///
    /// Idempotent: a second begin inside a live preview is an update, so no re-entry into the
    /// gesture can re-anchor the origin the user has been watching.
    func beginPreview(at requested: CMTime) {
        guard flight?.stage != .previewing else { return updatePreview(to: requested) }
        flight = SeekFlight(id: nextFlightID(), played: concretePosition,
                            requested: requested, stage: .previewing)
    }

    /// The preview moved. Same flight, same origin, same identity — only the promise changes.
    func updatePreview(to requested: CMTime) {
        guard let live = flight, live.stage == .previewing else { return }
        flight = SeekFlight(id: live.id, played: live.played,
                            requested: requested, stage: .previewing)
    }

    /// The gesture ended without committing — an explicit cancel (tvOS Back out of a swipe
    /// scrub), or a drag released on a player that can't seek. The bar goes back to whatever it
    /// was showing BEFORE the gesture: a still-unlanded commit if one stands (the preview
    /// superseded it, and cancelling hands it back — with the preview's own id, so nothing that
    /// is already drawn restarts), or nothing at all.
    func cancelPreview() {
        guard let live = flight, live.stage == .previewing else { return }
        flight = seekHold.map {
            SeekFlight(id: live.id, played: live.played, requested: $0.target, stage: .committed)
        }
    }

    private func nextFlightID() -> UInt64 {
        lastFlightID += 1
        return lastFlightID
    }

    func commitScrubSeek(to target: CMTime, resume: Bool) async {
        // Exit fence, and the load-bearing one: every scrub surface COALESCES its commit
        // (`SeekCommitCoalescer`, ~400ms), so a drag released just before the close button
        // lands here inside the dismiss animation, and its `resume` branch would call
        // `engine.play()`, unmuting and restarting the audio the exit just ended. The
        // engine's own latch refuses that play; this refuses to issue it at all.
        guard !isExiting else { return }
        // Publish the destination BEFORE the seek. An out-of-buffer transcode
        // commit re-anchors, and `performTranscodeReload` raises the `.loading` scrim and
        // drops every engine beat for its whole duration — so without this the bar would
        // keep reading the pre-scrub clock behind the scrim and snap back to A. The hold keeps
        // it there — moving only with the engine's own `.projected` beats — until an
        // `.observed` one lands: the seek-settle contract's "this is my clock, with no seek of
        // mine outstanding" (`PositionProvenance`).
        // The `.previewing` → `.committed` transition, and the ONE place the chaining rule
        // lives: the new flight's A is `concretePosition` rather than `currentPosition`, so a
        // commit made while an earlier one is still unlanded inherits the position the picture
        // never left. Reading the displayed position here would span from a target nothing ever
        // played, and the crossing would launch from a dot that has been sitting at the real A
        // all along. A fresh id supersedes whatever was in flight: the bar drops the old span on
        // an integer compare, with no tolerance to get wrong.
        flight = SeekFlight(id: nextFlightID(), played: concretePosition,
                            requested: target, stage: .committed)
        seekHold = SeekHold(target: target, armedAt: seekHoldNow())
        lastPosition = target
        currentPosition = target
        // Now Playing extrapolates its clock from the last write, and a re-anchor drops
        // every engine beat for seconds — so without this the lock screen counts on from
        // the PRE-scrub position while the in-app bar sits on the target.
        nowPlaying.update(position: target, duration: currentDuration,
                          isPlaying: desiredPlaying, title: itemTitle)
        let didReanchor = await seek(to: target)
        // The head of the trail. Everything downstream (the session transition, that session's
        // first live beat) is only readable against the commit that asked for it: where the
        // user went, whether it rebuilt the transcode, and what transport it owes them back.
        Log.playback.info(
            """
            scrub commit: target=\(CMTimeGetSeconds(target), format: .fixed(precision: 1), privacy: .public)s \
            reanchor=\(didReanchor, privacy: .public) resume=\(resume, privacy: .public)
            """
        )
        // Re-check: `beginExit()` is synchronous MainActor work and can land while this
        // commit is suspended inside the seek above, whose fenced return (`false`) is
        // indistinguishable from an ordinary in-stream seek.
        guard !isExiting else { return }
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
            ) else {
                // Also drop any target queued during the failed attempt: the fallback
                // resumed the OLD stream, and a stale drain against it would fight the
                // user's next (fresh) scrub.
                pendingReanchorTarget = nil
                break
            }
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
        // Cancellation shield: every scrub surface cancels its in-flight commit when
        // newer input lands (`scrubCommitTask?.cancel()`, `SeekCommitCoalescer`), and
        // that cancellation must not ride into a half-done reload — by this point the
        // outgoing encode job is dead, the surface is frozen and the phase is pinned
        // to .loading, so dying mid-flight strands the scrim with nothing left to
        // emit a recovering beat. Run the reload on its own task so it always reaches
        // an outcome; the ONLY abort signal is the exit fence (`isExiting`, checked
        // at every await via `checkStillActive`), which `beginExit()` arms
        // synchronously before `stop()` runs.
        await Task {
            await performTranscodeReload(
                resumeAt: resume,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex
            )
        }.value
    }

    /// **The standing session ends where the app decides to reload, not where the engine
    /// gets around to it.** The engine's stamp can only advance inside `load()`, which is
    /// several awaits and (on device) several seconds away: the encode kill, the stop
    /// report, the whole re-resolve. For that entire window the OUTGOING `AVPlayerItem` is
    /// still mounted and still publishing — beats at the pre-scrub clock, and its own
    /// failure on the playlist whose ffmpeg job this reload just killed. Both were adopted,
    /// because both carried the session that was still active.
    ///
    /// So the rule is the app's to state: `activeSession` goes to nil here, at the decision
    /// (nil already means "nothing published is ours" — `stop()` uses it that way), and
    /// `loadAndPlay` installs the replacement when `load()` returns. The only path that puts
    /// the OLD stream back on screen — `fallBackAfterFailedSwitch`, after a failed
    /// re-resolve — puts its session back with it; an exit through this window is `stop()`'s.
    private func performTranscodeReload(
        resumeAt resume: CMTime,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async -> TrackSwitchOutcome {
        // The chips stay mounted through .loading — a second pick (or seek) mid-reload
        // must wait for (not race) the in-flight reload.
        guard !isSwitchingTracks, let item = playingItem else {
            // The re-anchor is not happening, and `drainReanchorSeeks` drops the target on any
            // non-`.completed` outcome — so a hold armed at it now points at a place nothing
            // will play. Same reasoning (and same fix) as `fallBackAfterFailedSwitch`: hand the
            // bar and the resume point back to whatever stream is actually running.
            seekHold = nil
            return .abandoned
        }

        // Keep the engine + its layer alive across the reload (beginPlayback reloads
        // it). Suppress the outgoing stream's trailing beats while we do.
        isSwitchingTracks = true
        defer { isSwitchingTracks = false }

        // The decision point — see the doc above. Everything the outgoing media publishes
        // from here on describes a stream this player has already walked away from, and the
        // id is kept so the trace can still name what was superseded and the fallback can put
        // it back.
        let superseded = activeSession
        activeSession = nil
        let closingPlaySession = resolved?.playSessionID

        // Freeze the current frame at the moment of the swap — the frosted cover
        // frosts over it while the new transcode buffers, and silencing stops the
        // outgoing audio instead of letting it play on under the cover (`silence()`,
        // not `pause()`: VLC's pause can lag behind a blocked input read while audio
        // keeps draining; the next `play()` restores audio — including the no-reload
        // fallback resume after a failed switch). The snapshot
        // (not the layer) is what actually holds the frame: `replaceCurrentItem` can
        // flush AVPlayerLayer to black (see `AVKitVideoLayerHost.onFreezeReady`).
        // Taken BEFORE the silence's await so the frame on screen is the live one.
        freezeVideoSurface()
        await engine?.silence()
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
        //
        // The other cost of this order, and why it stays anyway: the outgoing item is still
        // attached for the whole re-resolve, playing a playlist whose ffmpeg job just died —
        // so it can fail on its own (device-confirmed: `CoreMediaErrorDomain -19602` on the
        // session's `master.m3u8`). Deferring the kill until after the resolve would trade a
        // cosmetic failure for the encode contention the comment above was written for, which
        // is device-diagnosed and unrecoverable. It costs nothing instead, because the session
        // was closed above: that failure — and every ordinary beat the abandoned item keeps
        // publishing at the pre-scrub clock — carries a session no longer active, so `handle`
        // drops it.
        let boundary = ContinuousClock.now
        await stopEncodingIfNeeded()
        await reportStoppedIfNeeded()
        // The boundary the whole re-anchor trail hangs off: after this line the outgoing
        // ffmpeg job is dead and nothing has replaced it yet. The play session is named in
        // clear so a later failure log can be read against the URL it carries — the abandoned
        // stream and its replacement differ by nothing else — and the elapsed time is what
        // separates "the kill was slow" from "the re-resolve was".
        Log.playback.info(
            """
            reload boundary: superseded=\(superseded?.description ?? "none", privacy: .public) \
            playSession=\(closingPlaySession ?? "—", privacy: .public) \
            killed+reported in \(Self.millis(since: boundary), privacy: .public)ms, \
            re-resolving at \(CMTimeGetSeconds(resume), format: .fixed(precision: 1), privacy: .public)s
            """
        )
        didReportStart = false
        didReportStopped = false
        didStopEncoding = false
        // The reload dispatches a fresh engine.play() below (via beginPlayback →
        // loadAndPlay), which re-arms startupClockStart — this session's old metric
        // must not linger on screen until that beat lands.
        startupClockStart = nil
        startupMillis = nil
        // The delivery verdict belonged to the outgoing session (a burn-in subtitle
        // switch can flip the video to a re-encode, and a re-anchor opens a fresh
        // session) — drop the stale verdict so the delivery debug row shows
        // "probing…" until the new session's first `.playing` beat re-probes.
        deliveryProbeTask?.cancel()
        deliveryProbeTask = nil
        transcodeDelivery = nil
        // A stale "exhausted" from the outgoing session must not carry over: the debug row
        // gates on this flag when `transcodeDelivery` is nil, and without the reset it would
        // show "no delivery info" for the whole reload window instead of "probing…" until
        // `startDeliveryProbe` re-arms on the new session's first `.playing` beat.
        deliveryProbeExhausted = false

        do {
            try await beginPlayback(
                item: item,
                startTime: resume,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                reusingEngine: true,
                superseding: superseded
            )
            return .completed
        } catch is CancellationError {
            // Exit raced the reload — stop() already owns the teardown. The shield in
            // `reloadTranscode` guarantees the exit fence is the only cancellation
            // source; verify it, because a bare `.abandoned` restores no state and a
            // NON-exit cancellation would strand the .loading scrim forever.
            guard isExiting else {
                return await fallBackAfterFailedSwitch(
                    .unexpected("transcode reload cancelled mid-flight",
                                underlying: AnySendableError(CancellationError())),
                    restoring: superseded
                )
            }
            return .abandoned
        } catch let error as AppError {
            return await fallBackAfterFailedSwitch(error, restoring: superseded)
        } catch {
            Log.playback.error("transcode reload failed: \(error.networkDiagnostic)")
            return await fallBackAfterFailedSwitch(
                .unexpected("transcode reload failed", underlying: AnySendableError(error)),
                restoring: superseded
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
    ///
    /// `restoring` is the session `performTranscodeReload` closed when it decided to reload.
    /// Wherever the old engine is still mounted — the resume below, and the exit that leaves it
    /// on screen for the slide-out — that session goes back with the stream, or it would play on
    /// with every beat dropped: a frozen clock over moving video. A nil engine is the other
    /// case: `beginPlayback` already tore it down and `tearDownEngine` closed the session for
    /// good, so there is nothing to restore it to.
    private func fallBackAfterFailedSwitch(
        _ error: AppError,
        restoring standing: PlaybackSessionID?
    ) async -> TrackSwitchOutcome {
        if engine != nil { activeSession = standing }
        // Exit can race the failed switch: beginExit() lands while the re-resolve is
        // suspended, and a real (non-cancellation) error then skips beginPlayback's
        // checkStillActive guards entirely. Resuming here would restart audio under
        // a dismissed player — stop() owns the teardown, so just walk away.
        guard !isExiting else { return .abandoned }
        guard let engine else {
            // The reload froze the surface before tearing the engine down; nothing will
            // emit a live beat now, so release the held frame here or it outlives the
            // failure (and an in-place retry would play under a pinned stale snapshot).
            unfreezeVideoSurface()
            phase = .failed(error)
            await audioSession.deactivate()
            return .failed
        }
        // The re-anchor never happened: this resumes the OLD stream at the OLD position, so
        // a hold armed at the seek target now points at a place nothing will play. Left
        // standing it pins the bar there until the resumed stream's first beat, and leaves
        // `lastPosition` (the resume/PlaybackStopped point) on the target in the meantime —
        // so a dismissal in that window records a place nothing ever played. Dropping it
        // here hands both back to the resumed stream at once.
        seekHold = nil
        phase = .playing
        desiredPlaying = true
        await engine.play()
        return .fellBack(error)
    }

    // MARK: - Private

    /// Consumes `engine`'s beats until its stream finishes or this subscription is
    /// replaced — and replacing ENDS the outgoing one first. An orphaned consumer only
    /// stops when the OLD engine's stream finishes, which is teardown's job, so leaving
    /// it standing is what keeps a replaced engine retained and beating.
    private func subscribe(to engine: any PlaybackEngine) {
        stateTask?.cancel()
        let stream = engine.state
        stateTask = Task { [weak self] in
            for await beat in stream {
                await self?.handle(beat, from: engine)
            }
        }
    }

    /// The two identity questions a beat has to answer, and they are different questions.
    ///
    /// The ENGINE: cancellation is not synchronous, so a beat already pulled from a replaced
    /// engine's stream can still be waiting for its MainActor hop when the replacement is
    /// installed, and adopting it would report the dead engine's phase and position against
    /// the live one.
    ///
    /// The SESSION within that engine: a reload keeps the engine, so engine identity says
    /// nothing about which media a beat describes. The stamp does, and it is applied where the
    /// beat is PUBLISHED — which is what makes it survive the stream's buffer and the hop that
    /// every flag-based answer to the same question loses to.
    private func handle(_ beat: PlaybackBeat, from engine: any PlaybackEngine) async {
        guard self.engine === engine else { return }
        // Ahead of the session gate, deliberately: the hold's watchdog exists for the windows
        // where beats are dropped, and a superseded session's beat is still proof that time is
        // passing. It never adopts a position — see `publish`.
        if let hold = seekHold, seekHoldNow() - hold.armedAt >= SeekHold.watchdog {
            seekHold = nil
        }
        guard beat.session == activeSession else { return }
        await handle(beat.state)
    }

    /// The ONE writer of `currentPosition` for engine beats — every `.playing`/`.paused`/
    /// `.buffering` position goes through here so the in-flight `seekHold` can't be
    /// bypassed by one branch. Everything else about the beat (phase, duration, buffered,
    /// reporting) is the caller's and is unaffected.
    ///
    /// While a hold stands the two published positions come apart, along the seam
    /// `PositionProvenance` cuts:
    ///  • `.stale` — the engine's clock, still behind its own seek. Written nowhere: it is the
    ///    pre-seek position, and showing it is the scrub snap-back itself.
    ///  • `.projected` — the engine's forward estimate off the committed target (VLC's
    ///    extrapolation while libvlc's clock catches up, either engine's target echo). Written
    ///    to `currentPosition` ONLY: the picture really is running from the target, so the bar
    ///    must advance with it instead of freezing for the whole hold. Not to `lastPosition`
    ///    — the resume point stays the committed target until an observed clock confirms one,
    ///    so a dismissal mid-reload records where the user seeked TO, not a guess about how
    ///    far the guess has run.
    ///  • `.observed` — the engine owns the position again: release, and write both.
    ///
    /// **The rule, stated once, and it is the same with or without a hold armed:** `.observed`
    /// writes both, `.projected` writes `currentPosition` only, `.stale` writes nothing. The
    /// hold decides who ends the window, never who may be believed — and the no-hold route is
    /// not a safe place to relax it. A `.projected` beat with no hold is the engine's guess off
    /// a seek the VM never committed (a PiP/remote scrub, an engine-internal re-anchor, or a
    /// hold this VM's own watchdog already dropped while the engine is still projecting), and
    /// writing it to `lastPosition` persists a fabricated extrapolation as the resume point.
    ///
    /// `.stale` is dropped on every route for the mirror reason: with no hold armed it is
    /// still the position an unresolved seek moved away from, and on RELEASE it is the watchdog
    /// firing on whatever beat happened to arrive — ending the hold is right, adopting that
    /// position is the snap-back.
    ///
    /// The split the callers must respect: USER-FACING surfaces (the bar, Now Playing) read
    /// the held clock (`currentPosition`), while `playbackInfo.reportStart`/`reportProgress`
    /// report the engine's RAW position — the server's session clock must stay honest even
    /// while the UI is pinned. `reportStopped` is the exception that proves it: it reports
    /// `lastPosition`, which IS the target while a hold stands, because a dismissal
    /// mid-reload has to resume where the user seeked to.
    private func publish(position: CMTime, provenance: PositionProvenance) {
        // An invalid/indefinite CMTime is not a position (AVPlayer before the item's duration
        // resolves, VLC between media). Dropped HERE, ahead of the hold, so no route reaches
        // `currentPosition` with a NaN the bar's fraction, the remaining-time label and the
        // resume point would all inherit.
        guard CMTimeGetSeconds(position).isFinite else { return }
        guard let hold = seekHold else {
            // No hold does not make a beat any more believable than the engine said it was.
            // `.stale` is the position an unresolved seek moved AWAY from — writing it is the
            // scrub snap-back with the hold merely absent — and `.projected` is still a guess
            // off a target: display-safe, so the bar follows it, but never a resume point.
            switch provenance {
            case .stale: return
            case .projected: currentPosition = position
            case .observed:
                lastPosition = position
                currentPosition = position
            }
            return
        }
        switch hold.absorb(provenance: provenance, now: seekHoldNow()) {
        case .hold:
            // The bar follows the engine's own projection off the target and freezes on a
            // clock that is still behind it. `lastPosition` follows neither: until an observed
            // clock lands, the committed target is the only defensible resume point.
            if provenance == .projected {
                currentPosition = position
                // `.projected` is display-safe by contract: the picture is at, or running from,
                // this position. So the flight has stopped hiding a jump — the honest position
                // is the published clock again, and the concrete indicator stops claiming the
                // video sits at A for the whole (multi-second, on a VLC re-anchor) settle.
                if flight?.stage == .committed { flight?.stage = .landing }
            }
        case .release:
            seekHold = nil
            // Dropping the hold and ADOPTING the beat are two decisions, and the watchdog is
            // where they come apart: it releases on whatever beat happened to arrive, which
            // can be `.stale`. Ending the hold is right — an engine that never observes again
            // must not freeze the bar forever — but taking the pre-seek clock it carries is
            // the snap-back the hold existed to prevent, now performed by the exit itself.
            guard provenance != .stale else { return }
            lastPosition = position
            currentPosition = position
        }
    }

    /// The shared half of the two LIVE beats: a beat that proves the surface is rendering,
    /// playing or not. Releases the held frame, and decides whether the surface may leave
    /// `.loading` — `.playing` always may (frames are moving), a `.paused` beat only when it is
    /// the reload's first, which is a SESSION question and belongs here rather than smuggled
    /// out of a rendering helper's return value.
    ///
    /// Returns whether this was the reload's first live beat.
    @discardableResult
    private func noteLiveBeat(framesMoving: Bool) -> Bool {
        // The exit fence is `unfreezeVideoSurface()`'s and it belongs there — while dismissing,
        // the frozen frame is the card's, not this session's, and nothing may uncover it.
        let firstAfterReload = reloadAwaitingFirstLiveBeat && !isExiting
        reloadAwaitingFirstLiveBeat = false
        unfreezeVideoSurface()
        if framesMoving || firstAfterReload { phase = .playing }
        if firstAfterReload {
            // Closes the trail the session transition opened: which transport the reloaded
            // session came back on, and what the surface did with it. A reload that never
            // happened has nothing armed here, so it cannot print a line about one.
            Log.playback.info(
                """
                reload's first live beat: \(framesMoving ? "playing" : "paused", privacy: .public) \
                phase=\(String(describing: self.phase), privacy: .public)
                """
            )
        }
        return firstAfterReload
    }

    /// The reporting half of a live beat. `opensSession` — whether this beat may be the one
    /// that reports PlaybackStart: every `.playing` beat may, and so may a re-anchor's first
    /// live beat, which is a paused one whenever the user scrubbed while paused. Jellyfin
    /// expects a start before any progress, so a `.paused` beat that is neither (a remote/PiP
    /// pause landing during a cold start's buffering) still reports nothing.
    private func reportLiveBeat(position: CMTime, isPaused: Bool, opensSession: Bool) async {
        guard let resolved else {
            // SMB/local: no server session, so the beat persists the position locally instead
            // (same throttle; a pause right before dismissal is covered by stop()'s final save,
            // gated only on a nonzero position — see stop()).
            if smbSession != nil { saveSMBResumeThrottled() }
            return
        }
        if didReportStart {
            await playbackInfo.reportProgress(beat(position: position, isPaused: isPaused, from: resolved))
        } else if opensSession {
            didReportStart = true
            await playbackInfo.reportStart(beat(position: position, isPaused: isPaused, from: resolved))
            // The session is live: ffmpeg is running, so probe what it's actually doing to the video.
            startDeliveryProbe(for: resolved)
        }
    }

    /// Every beat here has already proved it belongs to the live engine AND the live session
    /// (`handle(_:from:)`), so there is nothing left to gate on: a reload's outgoing beats, a
    /// dying engine's trailing ones and a superseded item's late callbacks never arrive.
    private func handle(_ state: PlaybackState) async {
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
                let subtitleMenu = Self.directPlaySubtitleMenu(
                    engineTracks: tracks.subtitles,
                    resolved: resolved,
                    smbExternals: smbExternalSubtitleTracks
                )
                availableSubtitleTracks = subtitleMenu.tracks
                subtitleRowIDsByStream = subtitleMenu.rowIDsByStream
                // Reflect the engine's default selection so the menus show a
                // checkmark on the track that's actually playing. Don't clobber
                // a choice the user already made (a late/duplicate .ready).
                if selectedAudioTrack == nil {
                    selectedAudioTrack = tracks.audio.first { $0.id == tracks.selectedAudioID }
                }
                // Adopt the engine's own subtitle pick only when the engine is what
                // draws — the SAME predicate `directPlaySubtitleTracks` built the menu
                // from, so the two can never disagree. When we render every subtitle
                // ourselves (`engineSubtitlesDisabled`) its "selection" is a phantom
                // that would tick a row nothing is drawing.
                if Self.engineRendersSubtitles(resolved), let engineID = tracks.selectedSubtitleID {
                    // Looked up in the PUBLISHED menu, not the raw inventory: the rows
                    // are already normalized (the chip shows `displayName` directly, so
                    // a raw adoption would flash "SubRip" while the menu reads
                    // "English"), and only a row that exists can be ticked.
                    if let row = availableSubtitleTracks.first(where: { $0.id == engineID }) {
                        if selectedSubtitleTrack == nil { selectedSubtitleTrack = row }
                    } else if resolved != nil {
                        // The engine auto-selected a stream WE draw client-side — its
                        // menu row carries a `.jellyfinStream` id, so no row matches.
                        // Left alone it would paint a second copy under our overlay
                        // (the double-subtitle bug, in the one shape `:no-spu` can't
                        // cover: an item with image subs keeps the SPU renderer on).
                        await engine?.setSubtitleTrack(nil)
                    }
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
        case .playing(let position, let duration, let buffered, let provenance):
            noteLiveBeat(framesMoving: true)
            // First `.playing` beat of this session: land the startup metric and consume
            // the anchor so a later `.playing` (resume-from-pause, post-stall) never
            // overwrites it. `nil` when this beat isn't the first (already consumed).
            if let clockStart = startupClockStart {
                startupClockStart = nil
                startupMillis = Self.millis(since: clockStart)
            }
            isPlaying = true
            clearStall()
            publish(position: position, provenance: provenance)
            applyDuration(duration)
            bufferedTo = buffered
            nowPlaying.update(position: currentPosition, duration: duration, isPlaying: true, title: itemTitle)
            // Jellyfin: report to the server session. SMB: persist the position locally —
            // same beat, same ~10s throttle discipline as the progress report.
            await reportLiveBeat(position: position, isPaused: false, opensSession: true)
            // One-shot SMB thumbnail backfill: first `.playing` only (the flag is consumed
            // here; resume-from-pause / post-stall beats skip it). Schedules an 8s-delayed
            // low-priority capture so startup churn and an often-black first frame don't
            // poison the cache — see `scheduleThumbnailBackfill()`.
            if smbSession != nil, !didScheduleThumbnailBackfill {
                didScheduleThumbnailBackfill = true
                scheduleThumbnailBackfill()
            }
        case .paused(let position, let duration, let buffered, let provenance):
            // A LIVE beat like `.playing`: a paused AVPlayer still renders the frame it seeked
            // to, so this releases the held frame — and when it is the re-anchor's first live
            // beat it also takes the cover down and opens the session for reporting. `.playing`
            // as a phase means "the surface is live", not "frames are moving": the transport
            // glyph reads `desiredPlaying`.
            let firstAfterReload = noteLiveBeat(framesMoving: false)
            isPlaying = false
            clearStall()
            publish(position: position, provenance: provenance)
            applyDuration(duration)
            bufferedTo = buffered
            nowPlaying.update(position: currentPosition, duration: duration, isPlaying: false, title: itemTitle)
            await reportLiveBeat(position: position, isPaused: true, opensSession: firstAfterReload)
        case .buffering(let position, let duration, let buffered, let provenance):
            // Phase and isPlaying are untouched: the surface stays up and the
            // user's intent is still "playing" — only the stall flag changes,
            // driving the light scrim. No progress report either: the position
            // isn't advancing, and a beat here could race reportStart.
            //
            // A seek fetch is real by construction, so its scrim shows immediately (no 400ms
            // gap with a bare paused glyph). Two independent ways to know one is in flight,
            // and both are needed:
            //
            //  • The LABEL. A beat that is not `.observed` is the engine saying its own seek is
            //    unresolved — VLC's starvation scrim pinned at the target, AVKit's fetch under
            //    an open window. This covers a commit of ours without consulting the hold, and
            //    a seek we never issued but the engine did know about.
            //  • The JUMP. AVKit's PiP and `AVPlayerViewController` scrub the AVPlayer
            //    DIRECTLY, never through `seek(to:)`, so `inFlightSeeks` stays 0 and the
            //    resulting fetch is honestly labelled `.observed` — the engine has no idea a
            //    seek happened. A position discontinuity is the only evidence left.
            //
            // Contiguous `.observed` beats (mid-stream underruns, the momentary
            // evaluating-buffering flicker after an in-buffer resume) match neither and keep
            // the debounce, so they can't flash the scrim.
            let isSeekFetch = provenance != .observed
                || abs(CMTimeGetSeconds(position) - CMTimeGetSeconds(currentPosition)) > 2
            publish(position: position, provenance: provenance)
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
            desiredPlaying = false    // nothing left to resume; a terminal beat ends the intent too
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
            // Some MP4-family files pass the SMB pre-flight probe (or arrive as an
            // ordinary Jellyfin direct-play stream) but fail at DECODE time — a damaged
            // bitstream or an open-GOP cut the probe can't see. AVKit surfaces that as
            // this same terminal `.failed`, mid-load or mid-playback. One reactive
            // re-route to VLCKit per session, on the same asset — see
            // `attemptReactiveFallback`. Every other failure (a VLC failure, a second
            // MP4 failure, an HLS transcode) falls through to the ordinary error scrim.
            if let asset = currentAsset, let engine,
               ReactiveFallback.shouldReroute(
                   currentEngine: engine.id,
                   container: asset.hints.container,
                   alreadyRerouted: didReactivelyReroute,
                   error: error
               ) {
                // Latched HERE, not in the fallback: a second `.failed` beat arriving
                // before the hop below runs must not schedule a second retry.
                didReactivelyReroute = true
                // Set before spawning the hop: the UI must not sit on `.playing` (or
                // any other stale phase) until the hop actually runs the retry.
                phase = .loading
                // Unstructured hop (same shape as `.ended` above): this handler runs
                // INSIDE `stateTask`'s await loop, and the fallback cancels `stateTask` —
                // awaited inline, that self-cancellation trips the retry's own
                // `Task.checkCancellation()` and the fallback dies silently, leaving the
                // loading scrim up forever. Stored so `stop()` can cancel a hop that
                // outlives its session (the retry()/resetForReplay window).
                reactiveFallbackTask = Task { [weak self] in await self?.attemptReactiveFallback(from: asset) }
                return
            }
            isPlaying = false
            desiredPlaying = false    // nothing left to resume; a terminal beat ends the intent too
            clearStall()
            // A terminal beat also releases any held frame: no live beat will ever arrive to
            // do it, and a stale snapshot must not sit latched under the error scrim into a
            // retry. Still fenced while exiting, where the freeze is the dismissal's, not
            // this session's.
            unfreezeVideoSurface()
            // …and any seek hold, for the same reason: a failed session emits no further
            // position beat, so nothing else would ever hand the bar back. The error scrim
            // owns the screen from here; a target pinned under it would survive into the
            // retry as a resume point nothing ever played.
            seekHold = nil
            phase = .failed(Self.map(error))
        }
    }

    /// Reactive AVKit→VLC fallback: rebuilds `asset` (same url/headers/hints/vlcOptions —
    /// nothing about the SOURCE changes, only the engine) forced onto VLCKit, resuming
    /// from the current position if playback had progressed past the original start.
    /// `ReactiveFallback.shouldReroute` already gated this to exactly once per session
    /// (`didReactivelyReroute`) and to an AVKit failure on an MP4-family container.
    ///
    /// The failed AVKit engine is retired by the rebuild itself (`EngineSlot.swap`), not
    /// ahead of it: only the engine object and its state subscription die, never the SMB
    /// bridge or the Jellyfin encode job (`tearDownEngine` would reap both), because the
    /// retry reuses the exact same URL and still needs them alive. Mirrors the ordinary
    /// mid-session `.failed` handling (no `audioSession.deactivate()`): the session isn't
    /// over, VLC is just trying next.
    private func attemptReactiveFallback(from asset: PlayableAsset) async {
        // Exit can race the failure beat: beginExit()/stop() lands while this async
        // handler is running. Building a fresh VLC engine and starting audio under an
        // already-dismissing player would resurrect it after the fact — stop() owns the
        // teardown, so just walk away (mirrors fallBackAfterFailedSwitch's exit guard).
        guard !isExiting else { return }
        // `didReactivelyReroute` was already latched by the `.failed` handler that
        // scheduled this hop — before the hop, so a burst of failure beats can't
        // schedule twice.
        isPlaying = false
        clearStall()
        unfreezeVideoSurface()
        phase = .loading
        // Engine-namespaced state, cleared exactly like a session boundary: the VLC leg
        // inventories its own tracks from scratch, and `didApplyPreferredTracks = false`
        // lets it re-apply the server-preferred picks on its own first `.ready`.
        availableAudioTracks = []
        availableSubtitleTracks = []
        subtitleRowIDsByStream = [:]
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        didApplyPreferredTracks = false

        let resumeAt = CMTimeGetSeconds(currentPosition) > 0 ? currentPosition : asset.startTime
        let retryAsset = asset.replacingStartTime(resumeAt)

        // The failed AVKit engine is NOT retired here: `loadAndPlay` takes the rebuild
        // branch (the retry is forced onto VLCKit) and the slot swaps it out — cutting
        // its audio, keeping the video host mounted, and tearing it down behind the
        // reroute instead of in front of it.
        guard !Task.isCancelled, !isExiting else { return }

        do {
            try await loadAndPlay(retryAsset, reusingEngine: false, forcedEngine: .vlcKit)
        } catch is CancellationError {
            // Exit raced the retry — stop() owns the real teardown.
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            Log.playback.error("reactive VLC fallback failed (unmapped): \(error.networkDiagnostic)")
            phase = .failed(.unexpected("playback start failed", underlying: AnySendableError(error)))
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

    private func makeAsset(from resolved: ResolvedPlayback) -> PlayableAsset {
        PlayableAsset(
            url: resolved.url,
            headers: nil,
            hints: Self.deliveredHints(for: resolved),
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
            // The bundled Noto faces in the user's chosen design, for VLC's text
            // renderers (unused by AVKit): a directory for its internal libass — one
            // that also answers to libass' hardcoded default family, see
            // `VLCSubtitleFonts` — and a family name for its simple freetype renderer.
            subtitleFontsDirectory: VLCSubtitleFonts.directory(for: bundleFontDesign),
            subtitleFontFamily: VLCSubtitleFonts.freetypeFamily(for: bundleFontDesign),
            // The same style the client renderer draws external subs with, so a VLC-drawn
            // embedded SRT matches it instead of falling back to freetype's own defaults.
            subtitleTextStyle: engineSubtitleTextStyle,
            // Blind the engine's SPU renderer only when it has NOTHING left to draw:
            // every reported subtitle has a sidecar URL we fetch and render ourselves
            // (`subtitleStreamURLs` covers embedded text streams too). An item with a
            // PGS/VobSub stream keeps the renderer on — there is no sidecar for an
            // image sub, and VLC draws it locally for free. Where it does apply the
            // latch is stronger than a per-pick deselect: VLC keeps discovering text
            // tracks as the demux runs and auto-selects one.
            engineSubtitlesDisabled: resolved.clientRendersAllSubtitles
        )
    }

    /// The direct-play subtitle menu.
    ///
    /// **Jellyfin: the row's renderer decides its id, per stream.**
    /// `PlaybackInfoService` builds a sidecar URL for every TEXT stream — embedded
    /// ones included — so those become `.jellyfinStream` rows, fetched and drawn by
    /// our own libass, taking the user's settings and looking identical on both
    /// engines. An IMAGE stream has no sidecar, so it keeps the ENGINE's inventory row
    /// (`.vlc`/`.avKitOption`, joined to the server's metadata by
    /// `JellyfinTrackMatcher`) and the engine draws the bitmaps locally, for free.
    /// Only an image stream the engine can't be matched to falls back to a server
    /// burn-in pick — a full re-encode, so it is the last resort, not the default.
    ///
    /// **SMB keeps the engine's inventory**: there is no extraction endpoint for a
    /// local container, so its embedded tracks can only be engine-rendered. The
    /// filename-matched sidecars are appended.
    private static func directPlaySubtitleMenu(
        engineTracks: [SubtitleTrack],
        resolved: ResolvedPlayback?,
        smbExternals: [SubtitleTrack]
    ) -> DirectPlaySubtitleMenu {
        let streams = resolved?.mediaStreams.filter { $0.kind == .subtitle } ?? []
        guard let resolved, !streams.isEmpty else {
            return DirectPlaySubtitleMenu(
                tracks: engineTracks.map(normalizedEmbeddedSubtitle)
                    + (resolved.map(externalSubtitleTracks) ?? smbExternals),
                rowIDsByStream: [:]
            )
        }
        let engineByStream = engineTracksByStreamIndex(
            engineTracks: engineTracks,
            streams: streams,
            defaultStreamIndex: resolved.defaultSubtitleStreamIndex
        )
        let tracks = streams.map { stream in
            if resolved.subtitleStreamURLs[stream.index] != nil {
                return subtitleTrack(from: stream)          // text → we draw it
            }
            if let engineTrack = engineByStream[stream.index] {
                return engineRenderedSubtitle(stream: stream, engineTrack: engineTrack)
            }
            return subtitleTrack(from: stream)              // no renderer → server burn-in
        }
        return DirectPlaySubtitleMenu(
            tracks: tracks,
            // First writer wins, for the same reason `engineTracksByStreamIndex` says so:
            // a server that repeats a stream index is malformed, and the later row is no
            // better a guess than the first.
            rowIDsByStream: Dictionary(zip(streams.map(\.index), tracks.map(\.id))) { first, _ in first }
        )
    }

    /// The direct-play menu plus the join a *server preference* needs.
    ///
    /// A row's id names its RENDERER (`.jellyfinStream` for one we draw, `.vlc` /
    /// `.avKitOption` for one the engine draws), so nothing in the row itself says
    /// which server stream it came from. `rowIDsByStream` is that answer, recorded
    /// where the rows are built rather than re-derived later — a second derivation
    /// could disagree with the menu, and then a default would tick a row that isn't
    /// there. Empty on SMB/local, which has no server stream list at all.
    private struct DirectPlaySubtitleMenu {
        let tracks: [SubtitleTrack]
        let rowIDsByStream: [Int: TrackID]
    }

    /// Whether the ENGINE is what draws this session's subtitles — the read side of
    /// `PlayableAsset.engineSubtitlesDisabled`. Always true off-Jellyfin (SMB/local:
    /// the engine's inventory is all there is).
    private static func engineRendersSubtitles(_ resolved: ResolvedPlayback?) -> Bool {
        guard let resolved else { return true }
        return !resolved.clientRendersAllSubtitles
    }

    /// Joins the engine's own subtitle inventory to the server's stream list, so an
    /// image stream can be offered under the engine track that actually renders it.
    ///
    /// Deliberately matched against ALL subtitle streams, not just the image ones:
    /// narrowing the candidates would let a text engine track match the lone image
    /// stream by elimination and hand the menu the wrong id. `JellyfinTrackMatcher`
    /// returns nil for an ambiguous join (two same-language streams), which costs the
    /// image sub its engine row and falls it back to burn-in — degraded, never wrong.
    private static func engineTracksByStreamIndex(
        engineTracks: [SubtitleTrack],
        streams: [MediaStreamInfo],
        defaultStreamIndex: Int?
    ) -> [Int: SubtitleTrack] {
        var byStream: [Int: SubtitleTrack] = [:]
        for track in engineTracks {
            guard let stream = JellyfinTrackMatcher.matchedSubtitleStream(
                languageCode: track.languageCode,
                trackCount: engineTracks.count,
                streams: streams,
                defaultStreamIndex: defaultStreamIndex
            ) else { continue }
            // First writer wins: two engine tracks resolving to one stream is an
            // ambiguous join, and the later one is no better a guess than the first.
            if byStream[stream.index] == nil { byStream[stream.index] = track }
        }
        return byStream
    }

    /// A menu row for a stream the ENGINE renders: the engine's id (that's what
    /// `setSubtitleTrack` needs) under the server's naming (that's what a person
    /// picks by). Not `isBurnedIn` — nothing is re-encoded; the bitmaps are composited
    /// locally.
    private static func engineRenderedSubtitle(
        stream: MediaStreamInfo,
        engineTrack: SubtitleTrack
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: engineTrack.id,
            displayName: stream.menuLabel,
            languageCode: stream.language ?? engineTrack.languageCode,
            isForced: stream.isForced,
            detailLabel: TrackDisplay.subtitleFormatName(stream.codec),
            isExternal: stream.isExternal,
            isSDH: stream.isHearingImpaired,
            isBurnedIn: false
        )
    }

    /// External (sidecar) text subtitles from the server, as direct-play menu entries
    /// with `.jellyfinStream` ids. All sidecar text renders client-side
    /// (`SubtitleOverlayView`, fed by `loadSidecarSubtitle`, requesting ass/ssa/srt
    /// verbatim so authored styling survives) rather than through the engine — VLC
    /// can't shape sidecar text on iOS, and embedded subs already come from the
    /// engine's own inventory. Image subs are excluded here by policy: they go
    /// through server burn-in. Labels come from the server, so they read "English"
    /// etc. instead of VLC's generic "Track N".
    private static func externalSubtitleTracks(from resolved: ResolvedPlayback) -> [SubtitleTrack] {
        resolved.mediaStreams
            .filter { $0.kind == .subtitle && $0.isExternal && !$0.isImageSubtitle }
            .map(Self.subtitleTrack(from:))
    }

    /// Sidecar formats the client-side renderer (`ParallaxSubtitles`) ingests —
    /// authored ASS/SSA verbatim, SRT/VTT via its converter. Case-insensitive
    /// extension check.
    private static let renderableSidecarExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    /// SMB analog of `externalSubtitleTracks(from resolved:)` — there's no `resolved`
    /// stream list on the SMB path, only the filename-matched `[index: URL]` map + the
    /// resolver's `[index: label]`. Builds the same `.jellyfinStream`-id, client-rendered
    /// external tracks (so `selectSubtitleTrack` → `activateSidecarSubtitle` → the overlay
    /// path works identically) with the resolver's labels and the file extension as detail.
    /// Ordered by index for a stable menu.
    ///
    /// Filtered to `renderableSidecarExtensions` so a matched sibling in a format the
    /// renderer can't ingest (e.g. `.sub`/`.idx` image subs) never becomes a menu entry
    /// that draws nothing; `subtitleURLs` itself stays unfiltered.
    private static func externalSubtitleTracks(urls: [Int: URL], labels: [Int: String]) -> [SubtitleTrack] {
        let built = urls.keys.sorted().compactMap { index -> (track: SubtitleTrack, raw: String)? in
            guard let url = urls[index],
                  renderableSidecarExtensions.contains(url.pathExtension.lowercased())
            else { return nil }
            let format = url.pathExtension.uppercased()
            let detail = format.isEmpty ? "External" : "\(format) · External"
            // Translate the filename-derived label ("zh.hi", "en.forced") into the
            // same naming tier the Jellyfin path uses: localized language name +
            // SDH/forced flags. Labels with no recognised tokens ("Default", a
            // release-group tag) pass through verbatim. The language tag also
            // makes SMB sidecars visible to remembered-language matching.
            let raw = labels[index] ?? "Subtitle \(index + 1)"
            let info = SubtitleLabelInfo(label: raw)
            let track = SubtitleTrack(
                id: .jellyfinStream(index),
                displayName: info.displayName(fallback: raw),
                languageCode: info.languageTags.first,
                isForced: info.isForced,
                detailLabel: detail,
                isExternal: true,
                isSDH: info.isSDH
            )
            return (track, raw)
        }
        // Ambiguity guard: translation can collapse distinct labels onto one menu
        // row ("en" and "en.full" both read "English") — when name AND detail
        // collide, those tracks fall back to their raw labels; a pretty name the
        // user can't tell apart is worse than the filename tag it replaced.
        let rowCounts = Dictionary(
            built.map { (key: $0.track.displayName + "|" + ($0.track.detailLabel ?? ""), value: 1) },
            uniquingKeysWith: +
        )
        return built.map { track, raw in
            guard track.displayName != raw,
                  rowCounts[track.displayName + "|" + (track.detailLabel ?? ""), default: 0] > 1
            else { return track }
            return SubtitleTrack(
                id: track.id,
                displayName: raw,
                languageCode: track.languageCode,
                isForced: track.isForced,
                detailLabel: track.detailLabel,
                isExternal: track.isExternal,
                isSDH: track.isSDH
            )
        }
    }

    /// VLC's untitled-track fallback names, lowercased → the format name for the
    /// detail line. An MKV subtitle track with no authored title surfaces from
    /// libvlc as its codec description ("ASS", "SubRip", "UTF-8"…) — not a name a
    /// person picks a track by. When the track carries a language, swap in the
    /// localized language name (the same tier the Jellyfin path's `menuLabel`
    /// uses) and demote the format to the detail line. Authored titles ("Full
    /// Subs - [Japanese]") never match this table and pass through verbatim.
    private static let embeddedFormatFallbackNames: [String: String] = [
        "ass": "ASS", "ssa": "SSA", "srt": "SRT", "subrip": "SRT",
        "utf-8": "SRT", "utf8": "SRT", "vtt": "VTT", "webvtt": "VTT",
        "pgs": "PGS", "hdmv pgs": "PGS", "vobsub": "VobSub",
        "dvd subtitles": "VobSub", "dvb subtitles": "DVB",
        "tx3g": "Timed Text", "mov_text": "Timed Text", "t.140": "Timed Text",
        "microdvd": "SUB",
    ]

    /// Display normalization for ENGINE-inventoried (embedded) subtitle tracks —
    /// the engine reports raw container metadata; naming policy lives here.
    /// Only rewrites tracks whose name is a codec-fallback (table above) or a
    /// generic "Track N"/"Subtitle N" AND that carry a language code; everything
    /// else — authored titles, or fallbacks with no language to name — is kept.
    static func normalizedEmbeddedSubtitle(_ track: SubtitleTrack) -> SubtitleTrack {
        let lowered = track.displayName
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let format = Self.embeddedFormatFallbackNames[lowered]
        let isGenericNumbered = ["track", "subtitle"].contains { prefix in
            guard lowered.hasPrefix(prefix) else { return false }
            let rest = lowered.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
        guard format != nil || isGenericNumbered,
              let language = TrackDisplay.languageName(track.languageCode) else {
            return track
        }
        return SubtitleTrack(
            id: track.id,
            displayName: language,
            languageCode: track.languageCode,
            isForced: track.isForced,
            // An engine track that already carries a detail (AVKit tracks matched to
            // Jellyfin streams) keeps it — only VLC's nil gets the derived one.
            detailLabel: track.detailLabel ?? format.map { "\($0) · Embedded" } ?? "Embedded",
            isExternal: track.isExternal,
            isSDH: track.isSDH,
            isBurnedIn: track.isBurnedIn
        )
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
        case .loadTimedOut:
            return .playback(.startupTimedOut)
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

    /// What one source format is actually handed, given the appearance the overlay
    /// last pushed. Test-only window onto `effectiveStyleOverride` — the whole
    /// converted-vs-authored rule lives in that function and nothing else observes it.
    func debugEffectiveStyleOverride(for format: SubtitleSourceFormat) -> SubtitleStyleOverride? {
        effectiveStyleOverride(for: format)
    }

    /// The active engine's id, for the HUD's engine label.
    var debugEngineID: PlaybackEngineID? { engine?.id }

    /// Awaits the in-flight sidecar fetch+load (`subtitleFetchTask`) so a test can assert
    /// `subtitleRenderer`/`sidecarSubtitleInfo` deterministically instead of sleeping past the Task hop. The
    /// engine-beat analog is `FakePlaybackEngine.settle()`; this covers the ONE piece of
    /// per-selection work the VM detaches from the awaited call. No-op when none is in flight.
    func debugAwaitSubtitleFetch() async {
        await subtitleFetchTask?.value
    }

    /// Awaits the best-effort segments + adjacent-episode fetch (`segmentsTask`) that the
    /// `start` path deliberately detaches, so a test can assert `segments`/`adjacentEpisodes`
    /// without sleeping past its hop. No-op when none is in flight.
    func debugAwaitSegmentsLoad() async {
        await segmentsTask?.value
    }

    /// The engine's live decode snapshot (actual dimensions, bitrates, the true
    /// audio/subtitle selection). Polled by the HUD.
    func currentDebugSnapshot() async -> PlaybackDebugInfo {
        await engine?.debugSnapshot() ?? .empty
    }

    /// Live subtitle-delay nudge (`ms` absolute, positive = later) for an
    /// ENGINE-rendered track (VLC retimes; AVKit no-ops). Client-drawn sidecar cues
    /// are matched against the engine clock directly and have no retime path.
    func setSubtitleDelay(ms: Int) async {
        subtitleDelayMs = ms
        await engine?.setSubtitleDelay(milliseconds: ms)
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
            resolve: { _, _, _, _ in throw AppError.playback(.unsupportedFormat) },
            engineFactory: { _, _ in fatalError("preview VM never starts playback") },
            audioSession: PreviewAudioSession()
        )
        vm.itemTitle = "The Grand Budapest Hotel"
        vm.phase = .playing
        vm.isPlaying = true
        vm.desiredPlaying = true   // the transport glyph reads intent, so the preview must set it
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
        // A chaptered movie so the HUD previews render the full chip set (audio +
        // subtitles + speed + chapters) — the input the icon-only overflow fallback needs.
        // `playingItem` is the only source of `chapters` (a computed pass-through); the
        // display title still comes from `itemTitle` above, so this doesn't disturb it.
        let movie = Movie(
            id: ItemID(rawValue: "preview-movie"),
            title: "The Grand Budapest Hotel", overview: nil, year: 2014,
            runtime: .seconds(5_460), communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        )
        vm.playingItem = .movie(MovieDetail(
            movie: movie, tagline: nil, studios: [], directors: [], people: [],
            chapters: [
                Chapter(index: 0, name: "Opening", start: .seconds(0)),
                Chapter(index: 1, name: "The Lobby", start: .seconds(900)),
                Chapter(index: 2, name: "Finale", start: .seconds(5_400))
            ]
        ))
        return vm
    }
}

private struct PreviewAudioSession: AudioSessionControlling {
    func activate() async throws {}
    func deactivate() async {}
    let routeChanges = AsyncStream<Void> { _ in }
}
#endif

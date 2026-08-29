import Foundation
import CoreMedia
import OSLog
import Synchronization
import ParallaxCore
// VideoLAN ships the same VLCKit under two module names — MobileVLCKit on iOS,
// TVVLCKit on tvOS — so every VLC file in this package selects one this way. It is
// the one sanctioned exception to the no-platform-conditionals-in-Packages rule:
// it renames a module, no logic differs between the two branches.
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif

/// VLC-backed `PlaybackEngine`. Handles the long tail of formats AVKit cannot
/// decode: MKV/WebM containers, VC-1/MPEG-2/VP9 video, DTS/TrueHD audio,
/// ASS/SSA/PGS/VobSub subtitles.
///
/// **Concurrency model:**
/// `VLCMediaPlayer` is non-`Sendable`; the engine is pinned to `@MainActor` to
/// satisfy Swift 6. `VLCLibrary.sharedEventsConfiguration` is set to
/// `VLCEventsLegacyConfiguration()` once at app launch (see `configureVLCEvents()`),
/// routing delegate callbacks async to the main queue. Delegate methods are
/// declared `nonisolated` and assert main isolation via `MainActor.assumeIsolated`.
///
/// **Teardown order (critical):** detach drawable → nil delegate → stop → finish.
/// `player.media` is deliberately NOT nil'd — see `teardown()`.
@MainActor
public final class VLCKitEngine: NSObject, PlaybackEngine, VLCPlayerHosting {

    // MARK: - Protocol requirements

    public nonisolated let id: PlaybackEngineID = .vlcKit

    /// MobileVLCKit 3.x ships no Picture-in-Picture surface at all. The app reads
    /// `supportsPiP` to show or hide the PiP button, so reporting `false` here is what
    /// removes the affordance on this engine; AVKit still offers it.
    public nonisolated let capabilities = PlaybackEngineCapabilities(
        supportsPiP: false,
        supportsVideoAirPlay: false,
        supportsNowPlayingIntegration: true
    )

    public nonisolated let state: AsyncStream<PlaybackState>
    private nonisolated let continuation: AsyncStream<PlaybackState>.Continuation

    // MARK: - VLC internals

    // `nonisolated(unsafe)` is required because Swift 6 forbids `nonisolated let`/`var`
    // for non-Sendable types. It IS `let`: built once in `init`, either against the shared
    // `VLCLibrary` or a private one scoped to `libraryOptions` (see `init(libraryOptions:)`)
    // — never reassigned or swapped after that. The player is only ever mutated (delegate,
    // media, play/stop) from MainActor-isolated code; the nonisolated `vlcPlayer` accessor
    // is read-only and accessed synchronously from UIViewRepresentable contexts that cannot
    // hop to MainActor. The drawable handle contract (see `vlcPlayer` below) is unaffected
    // either way.
    private nonisolated(unsafe) let mediaPlayer: VLCMediaPlayer

    /// Every control the engine issues goes through this seam; in production it IS
    /// `mediaPlayer` (`VLCMediaPlayer` conforms verbatim), and `init(control:)` swaps in a
    /// spy so the poll loop and the latches can be tested without a decode.
    private nonisolated(unsafe) let player: any VLCPlayerControlling

    /// The underlying `VLCMediaPlayer`, exposed `nonisolated` so the app's
    /// `UIViewRepresentable` make/update contexts can wire the video output without
    /// a `MainActor` hop.
    ///
    /// **Read/set `drawable` ONLY.** All other mutations (play/pause/stop, `media`,
    /// `time`) are owned by `VLCKitEngine` and run on the `@MainActor`; calling them
    /// on this returned reference from another isolation domain races the engine's
    /// control path. The cast site (`VLCPlayerHosting`) must treat this as a
    /// drawable handle, not a control surface.
    public nonisolated var vlcPlayer: VLCMediaPlayer { mediaPlayer }

    /// VLC's snapshot reads no bytes at all — it grabs the frame already on the live decode
    /// surface, no fresh SMB I/O. See the protocol doc.
    public nonisolated let captureFramePerformsIO = false

    /// Live playback clock for the client-side subtitle overlay. Returns `.invalid` while
    /// there is no position worth drawing to (before the first frame, and for the whole
    /// resume-seek window) so the overlay skips rather than flashing the 0:00 cue.
    ///
    /// This is `displayClockMs`, NOT the raw `clockMs`: right after a `setTime` libvlc keeps
    /// reporting the PRE-seek position for seconds (see `pendingSeekMs`), so a renderer
    /// reading the raw clock draws the old timeline under a picture that has already moved,
    /// then snaps. The scrubber has always been protected by the holds in `heldPositionMs`;
    /// this makes the client renderer read the same value.
    public nonisolated var currentTime: CMTime {
        let ms = displayClock.load(ordering: .relaxed)
        return ms >= 0 ? Self.vlcTimeToCMTime(ms: ms) : .invalid
    }

    /// The position (ms) `currentTime` vends, mirrored out of the `@MainActor` state so a
    /// `nonisolated` read costs nothing. -1 = nothing to draw. Written by `publish(_:_:)`
    /// and nowhere else.
    ///
    /// Atomic rather than `nonisolated(unsafe)`: `currentTime` is public and advertised as a
    /// cheap off-actor read, so the first non-main caller (a `CADisplayLink`-driven overlay,
    /// a background progress reporter) would race the poll's 500 ms writes on a plain var.
    /// Relaxed ordering — the value stands alone, nothing is published through it.
    private let displayClock = Atomic<Int32>(-1)

    /// **The engine's single beat.** Every position the engine knows about goes through
    /// here: it mirrors that position into the nonisolated display clock, then yields
    /// `state` if there is one to yield.
    ///
    /// A `nil` state is a SUPPRESSED beat — the seek hold, `play()`'s pre-roll, a
    /// guarded-out position — and it still updates the mirror, which is the whole point:
    /// the client subtitle renderer needs a position on exactly the ticks the scrubber
    /// must not move. Funnelling both halves through one call is what keeps a
    /// yield-without-mirror (a jumping overlay) from being expressible.
    ///
    /// The mirror is forced to -1 while a resume offset is still pending: the resume seek
    /// has not been applied to the input yet, so neither the raw clock (still pre-seek) nor
    /// the pending offset (not on screen yet) describes the picture, and a renderer is
    /// better off drawing nothing for that window.
    private func publish(positionMs: Int32, _ state: PlaybackState? = nil) {
        displayClock.store(pendingStartMs == nil ? positionMs : -1, ordering: .relaxed)
        guard let state else { return }
        continuation.yield(state)
    }

    /// The live playback position in milliseconds, or -1 when libvlc has no clock yet.
    ///
    /// 3.x's `VLCTime.nullTime` reads `intValue == 0`, NOT -1 — treating
    /// `player.time.intValue` as a signed sentinel silently turns "no clock" into a real
    /// 0:00 beat, snapping the scrubber (and the saved resume point) to the start of the
    /// media. The honest signal is `VLCTime.value`, which is nil exactly when there is no
    /// clock; -1 is re-synthesized here so every downstream gate (`liveBeat`,
    /// `emitBuffering`) keeps its existing "negative = skip" contract.
    private nonisolated var clockMs: Int32 {
        Self.validClockMs(player.time) ?? -1
    }

    /// libvlc's demux byte counter, through the same seam every other player read goes
    /// through (`VLCPlayerControlling.demuxReadBytes`). 0 with no media of ours loaded, so a
    /// counter left over from a detached input can't read as a live fetch.
    private var demuxReadBytes: Int {
        currentMedia == nil ? 0 : player.demuxReadBytes
    }

    // MARK: - Playback state tracking

    private var currentMedia: VLCMedia?

    /// Drives the progress beats. VLC drops into `.buffering` freely during normal
    /// playback and its state transitions are not a trustworthy play/pause signal
    /// (VideoLAN VLCKit#578/#128/#80). Mirror `AVKitEngine`'s periodic time observer:
    /// poll the live clock on a timer and publish beats ourselves. `player.isPlaying`
    /// is the reliable play/pause signal (it reads `true` while the state says
    /// `.buffering`), so beats derive playing-vs-paused from it, never from
    /// `player.state`.
    private var progressTask: Task<Void, Never>?

    /// Last inventory the poll published, so it can re-emit `.ready` when the picture
    /// changes. 3.x has no per-track or length delegate, so the poll is the only place
    /// that can notice a late-discovered embedded text track, VLC settling its default
    /// selection (the first `.ready` ships with nothing selected, so the audio chip would
    /// keep the generic "Audio" label), or the container length finally resolving.
    /// Diffing rather than re-emitting every tick keeps it flood-free.
    /// The FULL built inventory is what's diffed — not just ids/selection — because the
    /// language and `isUnsupported` facts join in from `tracksInformation`, which can
    /// populate ticks after the player's track arrays; a narrower key would swallow that
    /// late arrival and the menu would never learn a track's language or undecodability.
    /// Reset to nil on every `load` so the first real inventory re-emits.
    private var lastPublishedInventory: TrackInventory?
    /// Rides alongside `lastPublishedInventory`: a length that resolves without any track
    /// change must still re-emit `.ready`.
    private var lastPublishedLengthResolved = false

    /// Resume offset (ms) to seek to once the demux is seekable, or nil. Resume is done
    /// by seeking — NOT the `:start-time` media option, which truncates the input so the
    /// scrubber can't span the full media or rewind before the resume point.
    private var pendingStartMs: Int32?

    /// Target (ms) of an in-flight user seek. Right after `setTime`, VLCKit's clock keeps
    /// interpolating from a now-stale reference and `player.time` briefly reads far past
    /// the target before the demux settles — surfacing as a scrubber overshoot that snaps
    /// back a poll later. The poll withholds the raw clock until it converges on this
    /// target, publishing an extrapolation off the target instead (`seekHoldPositionMs`);
    /// `pendingSeekPolls` is both that extrapolation's clock and a fallback so a
    /// keyframe-snapped landing a few seconds off the request still resumes live tracking.
    private var pendingSeekMs: Int32?
    private var pendingSeekPolls = 0
    /// The raw clock (ms) sampled immediately BEFORE the in-flight seek's `setTime`, or nil
    /// when libvlc had no clock then. The hold's give-up test reads it: after the poll budget
    /// runs out, a `clockMs` that is still nearer this than the target has not moved off the
    /// position the seek started from, so releasing the hold would republish the PRE-seek clock
    /// as a landed position (the bar snaps back to where the user seeked from, and the resume
    /// point follows). See `seekHoldShouldRelease`. Cleared wherever `pendingSeekMs` is.
    private var preSeekClockMs: Int32?
    /// Hold polls counted from the ORIGINAL seek rather than from the current re-anchor, and
    /// the difference is the whole point: `pendingSeekPolls` is the extrapolation's clock and
    /// the reassert escalation resets it every 6 ticks, so a budget counted on it can be
    /// refreshed forever by a wedged input. Only `seek()`, `load()`, `teardown()` and a
    /// release reset this one. See `seekHoldAbandoned`.
    private var seekHoldTotalPolls = 0
    /// Demux byte count sampled at the previous seek-hold poll, so the hold can tell a clock
    /// that hasn't republished yet from a fetch that has actually stopped (see
    /// `seekHoldAction`). Reset to 0 wherever a new `pendingSeekMs` is armed, so the first
    /// comparison always reads as "advancing" and can't flash a scrim.
    private var seekHoldReadBytes = 0
    /// Target (ms) of a seek that was issued while the engine was PAUSED, or nil.
    /// VLCKit 3.x applies a paused seek's demux/video position but does not flush the ~1-2s
    /// of decoded audio already queued in the aout (the same reservoir `silence()` documents;
    /// mute cannot reach it either). On the next resume that stale queue drains audibly —
    /// video sits at the new position while the soundtrack finishes the PRE-seek timeline
    /// for ~2s, on every format. A seek issued while PLAYING reaches that queue natively
    /// (the same flush `flushForImmediateRate` provokes deliberately), so `play()` consumes
    /// this latch by re-issuing the same setTime once running: same position, clean
    /// pipeline. Cleared by load()/teardown(), by any seek issued while playing, and by
    /// play() itself after the re-issue; pause() leaves it alone.
    private var pausedSeekTargetMs: Int32?
    /// Anchor (ms) the reassert-escalation nudge re-anchored at, pending a flush re-issue.
    /// The escalation's setTime runs while the input is stuck PAUSED (that is the branch's
    /// precondition), so like a paused user seek it cannot reach the aout's already-queued
    /// blocks — on recovery the re-anchored picture would sit over the pre-seek soundtrack.
    /// The live tick consumes this once `isPlaying` turns true again, re-issuing the
    /// setTime on a running input (the flush that works). Separate from
    /// `pausedSeekTargetMs`: the reassert loop drives `player.play()` directly, so
    /// `play()`'s consumption point never runs for this path. Cleared by load()/teardown().
    private var reanchorFlushMs: Int32?
    /// Consecutive poll ticks spent in the play-intent reassert branch (input paused
    /// against play intent). Drives the escalation nudge — see the reassert branch.
    private var reassertTicks = 0

    /// Read-rate duration estimate (ms) for media whose container length never resolves — see
    /// `estimateDurationMs`. CAPTURED ONCE (the first observed sample past the floor) and HELD: the
    /// read-rate stays representative only before a seek re-reads bytes out of order, and a stable
    /// total is what the scrub bar needs. 0 until captured (→ `.indefinite`, indeterminate bar);
    /// reset on every fresh `load`. Never used once `media.length` resolves to a real value.
    private var lastEstimateMs: Int32 = 0

    /// In-flight `captureFrame()` continuation. VLC's `saveVideoSnapshot(at:withWidth:andHeight:)`
    /// is fire-and-forget; the PNG lands on disk and surfaces via `mediaPlayerSnapshot(_:)`. The
    /// continuation bridges that into `async` with a timeout race — see `captureFrame()`. Nil'd
    /// immediately on resume so a late snapshot/timeout can never double-resume.
    private var snapshotContinuation: CheckedContinuation<Bool, Never>?
    /// Races the snapshot notification; cancelled when the notification arrives first (or on
    /// teardown) so a late timeout never touches a finished capture.
    private var snapshotTimeoutTask: Task<Void, Never>?
    /// Full path of the PNG the in-flight `captureFrame()` is waiting on. `mediaPlayerSnapshot(_:)`
    /// carries no identity of its own (VLCKit's notification payload names only the player), so this
    /// is the only way to tell a genuine snapshot for THIS capture apart from a stale notification
    /// for an earlier, already-timed-out capture whose write raced back in after the fact.
    private var snapshotExpectedPath: String?

    /// Source file size in bytes (from the SMB lister via `PlaybackHints`), or nil for streamed
    /// sources. The only way to convert the demux read-rate into a total runtime once `position`
    /// is out (see `estimateDurationMs`). Set on `load`.
    private var fileSizeBytes: Int64?

    /// Whether playback started from 0 (no resume offset). The read-rate runtime estimate divides
    /// `fileSize × playedMs / demuxBytes` and assumes both counters are zero-anchored; a resume
    /// seek makes `player.time` the resume offset while the demux counter starts near the seek
    /// target, so the estimate is only valid from a cold start. Set on `load` from the resume hint.
    private var estimateAnchoredAtZero = true

    /// Surfaces a `.failed` if no first frame arrives within the deadline — so a source that opens
    /// but never decodes can't strand the player on the loading scrim forever. Armed in `play()`,
    /// disarmed by the first beat / teardown / terminal state. See `LoadWatchdog`.
    private let loadWatchdog = LoadWatchdog()

    /// Bounds a mid-playback stall the poll detects (see `stallDetector`). `player.isPlaying` reflects
    /// intent, not frames (VLCKit#578), so a network death leaves the poll emitting `.playing` over a
    /// frozen clock forever — armed when the stall detector trips, and its expiry yields
    /// `.failed(.networkStalled)`. `lazy` so the `onExpiry` closure can capture `self`. See `StallWatchdog`.
    private lazy var stallWatchdog = StallWatchdog(deadline: stallDeadline) { [weak self] in
        self?.handleStallTimeout()
    }

    /// `stallWatchdog`'s deadline. `StallWatchdog`'s own 45s default in production; injectable
    /// through the test seam init because the arming rules (the stall detector, and the
    /// play-intent reassert's wedge) are only observable through the failure they eventually
    /// produce, and no suite can wait 45 wall-clock seconds for one.
    private let stallDeadline: Duration

    /// Frozen-clock + frozen-demux stall counter, fed once per poll ABOVE the seek hold — a seek
    /// in flight does not suspend a network death, and the hold's `continue` used to hide those
    /// ticks from it entirely. It owns `isStalled`/`stallWatchdog`: the hold branches decide only
    /// what to publish. Reset on load/pause/seek. See `StallDetector`.
    private var stallDetector = StallDetector()

    /// Whether the poll is currently publishing the honest `.buffering` stall scrim (detector tripped,
    /// watchdog armed). Gates a single arm on entry and a single `.playing`/disarm on recovery.
    private var isStalled = false

    /// The resume seek runs concurrently with playback (not awaited in `play()`), so it's
    /// stored here for `teardown()` to cancel — otherwise a dismiss during the readiness
    /// window would leave it polling and then write `player.time` on a stopped player.
    private var resumeTask: Task<Void, Never>?

    /// The USER's standing "no engine subtitle" intent for this session (Off, or the app
    /// is drawing an external sidecar itself). Set by `setSubtitleTrack`; cleared by each
    /// fresh `load`.
    private var subtitlesDisabled = false

    /// The ASSET's standing intent: it declared that the app draws every text subtitle
    /// itself (`PlayableAsset.engineSubtitlesDisabled`), so libvlc's SPU renderer must
    /// never draw one for its whole lifetime. The hard enforcement is the `:no-spu`
    /// media option applied in `applyOptions`; this latch closes the software half by
    /// making `setSubtitleTrack(_:)` refuse to select. Set on each fresh `load`.
    private var engineSubtitlesDisabled = false

    /// The two latches above, read as one: must the engine's subtitle be forced off
    /// right now? VLC discovers embedded text tracks as the demux runs and auto-selects
    /// a default/forced one — which would render THROUGH the client overlay — so the
    /// poll re-asserts the deselect every tick while this holds. One read site, so the
    /// user's intent and the asset's can't be enforced differently.
    private var mustSuppressEngineSubtitles: Bool {
        subtitlesDisabled || engineSubtitlesDisabled
    }

    /// Engine diagnostics (never URLs or media options — those can carry SMB credentials).
    private static let log = Logger(subsystem: "com.lhdev.parallax", category: "playback")

    /// User-selected playback speed (1.0 = normal). libvlc applies `rate` to the *active
    /// input*, so a rate set before the demux is up is dropped — exactly when
    /// `PlayerViewModel.beginPlayback` re-applies the persisted speed (right after `play()`).
    /// Persist the intent here and have the progress poll re-assert it once playback is live,
    /// mirroring `AVKitEngine`'s `desiredRate`. A *live* mid-playback change is otherwise inaudible
    /// until the old-rate buffer drains (≈ network-caching) — `flushForImmediateRate` re-decodes in
    /// place to apply it promptly.
    private var desiredRate: Float = 1

    /// The subtitle delay (ms) the user asked for. Scoped to the loaded media: `load()`
    /// resets it, like every other latch here — the app owns the per-item intent and
    /// re-applies it after a reload (see `setSubtitleDelay(milliseconds:)`).
    private var desiredSubtitleDelayMs = 0

    /// Whether the user wants playback running — set by `play()`/`pause()`, cleared on
    /// teardown and terminal states. libvlc applies play/pause on the input thread, and a
    /// resume issued while that thread is blocked mid-read can be DROPPED — the drag-scrub
    /// commit's `play()` right after a paused seek over a high-RTT share ("stream filter
    /// error: reading while paused"): the input stays paused, the poll stays silent
    /// (`isPlaying`-gated), and the frozen frame ships under a playing glyph. Same
    /// command-drop family as `desiredRate`: persist the intent and let the poll re-push
    /// it until the input obeys (see `shouldReassertPlay`).
    private var desiredPlaying = false

    /// The session is closing and its audio is gone for good (`endAudio()`). While set,
    /// `play()` and `pause()` are both inert: the exit path stops the player to cut audio at
    /// the render level, and a late resume (a scrub commit the coalescer released just before
    /// the close button, landing inside the dismiss animation) would unmute and restart the
    /// input behind the outgoing UI, while a late pause (the HUD scrubber, still hit-testable
    /// through the slide-out) would drive the same player that stop is winding down. Cleared
    /// ONLY by `load()`, which is what makes the engine-reusing transcode reload work;
    /// `silence()` deliberately never sets it.
    private(set) var audioEnded = false

    /// `endAudio()`'s detached `player.stop()`, kept joinable. `endAudio()` returns without
    /// waiting on it (returning immediately is the whole point), but every path that drives
    /// the player afterwards joins it first via `awaitPendingStop()`: two threads commanding
    /// one non-Sendable `VLCMediaPlayer` at once is exactly the shape libvlc's own teardown
    /// aborts on.
    private(set) var pendingStopTask: Task<Void, Never>?

    /// A detached `stop()` is in flight (or about to be), so the player belongs to another
    /// thread and NOTHING on the MainActor may write to it.
    ///
    /// `audioEnded` only makes `play()`/`pause()` inert, which left every other command
    /// live: a HUD scrubber is still hit-testable through the dismiss animation, so a scrub
    /// commit landing inside it wrote `player.time` on main while 3.x's synchronous `stop()`
    /// was winding the same non-Sendable `VLCMediaPlayer` down elsewhere — the two-threads-
    /// on-one-player shape libvlc aborts on with `Assertion failed: (p_md)`. Set by
    /// `endAudio()` and `teardown()` immediately before the stop is scheduled; cleared ONLY
    /// by `load()`, which is what keeps the engine-reusing transcode reload working.
    private(set) var isWindingDown = false

    /// The single gate every player-writing entry point checks. Returns true when the caller
    /// must no-op, and says so once in the log so a dropped command is traceable.
    private func refusedWhileWindingDown(_ command: String) -> Bool {
        guard isWindingDown else { return false }
        Self.log.info("\(command, privacy: .public) ignored: the player is winding down")
        return true
    }

    /// Schedules the detached `stop()` and raises the wind-down latch first, so the latch is
    /// never observable as "down while a stop is in flight". The ONLY place `pendingStopTask`
    /// is assigned — `endAudio()` and `teardown()` both come through here.
    ///
    /// Detached because 3.x's `stop()` is SYNCHRONOUS and winds the input down on the calling
    /// thread, which on SMB is routinely parked mid-network-read for seconds; inline on the
    /// MainActor that wait lands on the thread drawing the dismissal.
    func scheduleDetachedStop() {
        isWindingDown = true
        pendingStopTask = Task.detached { self.player.stop() }
    }

    /// Position (ms) captured when a rate-change flush re-decode began, or nil. While set, the
    /// progress poll publishes buffering beats at this hold point until VLC's clock advances past
    /// it (re-decode done) — so the rate-change re-buffer reads as a brief buffering moment, not a
    /// silently frozen counter. See `flushForImmediateRate`.
    private var rateFlushAnchorMs: Int32?
    /// Poll ticks elapsed in the current flush bridge; a budget so a re-decode that never cleanly
    /// advances past the anchor still resumes live tracking instead of holding forever.
    private var rateFlushTicks = 0

    // MARK: - Init

    /// `libraryOptions`: raw libvlc instance arguments (e.g. `--no-drop-late-frames`) for
    /// defects per-media options can't reach — the vout's `is_late_dropped` flag reads off
    /// the OWNING libvlc instance, not a per-media variable (proven on device), and
    /// `VLCMediaPlayer(options:)` is the only surface that can set instance-scoped flags.
    /// Decided at CONSTRUCTION so exactly one player ever exists per engine: a mid-`load`
    /// player swap would race the SwiftUI host, which binds `vlcPlayer.drawable` as soon
    /// as the engine is published. Nil = the shared library instance.
    ///
    /// The vendored `VLCLibrary.h` states the framework does not support multiple
    /// `VLCLibrary` instances. `VLCMediaPlayer(options:)` creates one anyway (it's the only
    /// surface that can set instance-scoped options), so this is knowingly off the
    /// documented path — device-exercised, though (playback + delegate events verified),
    /// and the only way to reach per-player library flags.
    public convenience init(libraryOptions: [String]? = nil) {
        let privateOptions = libraryOptions?.isEmpty == false ? libraryOptions : nil
        let mediaPlayer = Self.makePlayer(libraryOptions: privateOptions)
        self.init(mediaPlayer: mediaPlayer, control: mediaPlayer)
        // `_eventsConfigured` only attaches the audio diagnostics logger to
        // `VLCLibrary.shared()` — a private instance (exactly the defect files this is
        // tracing) never gets it. `player.libraryInstance` is the player's own library,
        // so attach it here too.
        #if DEBUG
        if privateOptions != nil {
            mediaPlayer.libraryInstance.loggers = [VLCAudioDiagnosticsLogger()]
        }
        #endif
        // NOTE: 3.x exposes no time-update cadence knobs. `player.time` here is the cached
        // value libvlc's own time-changed event refreshes, which fires as the input advances
        // rather than on a coarse 1s quantum — so the counter is fine-grained by default
        // and there is nothing to tighten.
    }

    /// Test seam: drives `control` for every command and clock read, while `vlcPlayer` keeps
    /// vending a real (idle, media-less) `VLCMediaPlayer` so the drawable-host contract still
    /// holds. Internal — the app has no reason to substitute a player.
    convenience init(control: any VLCPlayerControlling, stallDeadline: Duration = .seconds(45)) {
        self.init(mediaPlayer: Self.makePlayer(libraryOptions: nil), control: control,
                  stallDeadline: stallDeadline)
    }

    /// **The only place a `VLCMediaPlayer` is ever constructed.** Installing
    /// `VLCLibrary.sharedEventsConfiguration` has to happen BEFORE the first player (and
    /// therefore before the first `VLCLibrary`) exists, or delegate callbacks arrive off the
    /// main queue and every `MainActor.assumeIsolated` hop in this file traps. Touching
    /// `_eventsConfigured` from the designated init was too late: a convenience init's
    /// arguments — including `VLCMediaPlayer()` — are evaluated before the callee body runs.
    /// Funnelling construction through here makes the order structural instead of a
    /// convention each new init has to remember.
    static func makePlayer(libraryOptions: [String]?) -> VLCMediaPlayer {
        _ = _eventsConfigured
        guard let libraryOptions, !libraryOptions.isEmpty else { return VLCMediaPlayer() }
        return VLCMediaPlayer(options: libraryOptions)
    }

    /// The one designated init. `mediaPlayer` is the drawable handle `vlcPlayer` vends;
    /// `control` is the command seam — the same object in production, a spy in tests.
    private init(mediaPlayer: VLCMediaPlayer, control: any VLCPlayerControlling,
                 stallDeadline: Duration = .seconds(45)) {
        let (stream, cont) = PlaybackStateStream.makeStream()
        self.state = stream
        self.continuation = cont
        self.mediaPlayer = mediaPlayer
        self.player = control
        self.stallDeadline = stallDeadline
        super.init()
        player.delegate = self
    }

    // MARK: - PlaybackEngine

    public func load(_ asset: PlayableAsset) async throws {
        continuation.yield(.loading)
        // A reused engine (the transcode reload) can still be winding down `endAudio()`'s
        // stop on its own thread. Join it before handing the player fresh media.
        await awaitPendingStop()
        // The stop is joined, so the player is ours again: lower the wind-down latch and
        // re-attach the delegate `endAudio()` detached ahead of it.
        isWindingDown = false
        player.delegate = self
        lastPublishedInventory = nil
        lastPublishedLengthResolved = false
        engineSubtitlesDisabled = asset.engineSubtitlesDisabled
        subtitlesDisabled = false // the user's pick belongs to the outgoing media; the
                                  // asset's own intent is the latch above
        desiredSubtitleDelayMs = 0   // input-scoped, like every other latch here: new media
                                     // starts level. The VM re-applies the user's nudge after
                                     // a same-item reload (see PlayerViewModel.loadAndPlay).
        audioEnded = false        // a fresh stream reopens the session the exit latch closed
        pendingStartMs = Self.startMs(from: asset.startTime)
        publish(positionMs: -1)   // new media → nothing to draw until the first published position
        pendingSeekMs = nil
        preSeekClockMs = nil
        seekHoldTotalPolls = 0
        pausedSeekTargetMs = nil  // the new stream's aout starts empty; nothing to flush
        reanchorFlushMs = nil
        reassertTicks = 0
        rateFlushAnchorMs = nil   // a reused engine (track switch) must not bridge a stale flush
        stallDetector.reset()     // new media → fresh stall window (a reused engine must not carry a run)
        isStalled = false
        lastEstimateMs = 0        // new media → re-estimate from scratch (a reused engine must not
                                  // carry the previous item's read-rate runtime estimate)
        fileSizeBytes = asset.hints.fileSizeBytes
        estimateAnchoredAtZero = pendingStartMs == nil   // a resume offset invalidates the read-rate estimate
        // 3.x's `VLCMedia(url:)` is non-failable: libvlc accepts any URL here and only
        // reports an unplayable input later, through the `.error` player state, which
        // `handleStateChanged` already turns into `.failed(.assetNotPlayable)`.
        let media = VLCMedia(url: asset.url)
        applyOptions(to: media, asset: asset)
        currentMedia = media
        player.media = media
        // External subtitles are NOT slaved to the player: VLC's text renderers can't shape
        // sidecar SRT/VTT on iOS, so they're fetched + drawn client-side (SubtitleOverlayView)
        // the same way the transcode path is — see PlayerViewModel.makeAsset.
    }

    public func play() async {
        // The exit latch is terminal for this session: `endAudio()` already stopped the
        // player to cut audio at the render level, so a play arriving after it (a coalesced
        // scrub commit released inside the dismiss animation) must not unmute or restart
        // anything. Only `load()` reopens the session.
        guard Self.shouldHonorTransport(audioEnded: audioEnded),
              !refusedWhileWindingDown("transport") else { return }
        desiredPlaying = true
        // Release silence()'s mute here, not in load(): play() covers EVERY path that
        // resumes audio (a reload's fresh start, but also a bare resume after a failed
        // track-switch fallback), and unmuting at load() would lift the mute while a reused
        // engine's outgoing stream still has samples queued.
        player.audio?.isMuted = false
        player.play()
        // A seek that landed while paused never reached the blocks already queued in the
        // aout (see pausedSeekTargetMs): re-issue it now that the input runs, converting it
        // into the seek-in-place flush that drains them. Same position, so the demux barely
        // moves and the settle hold keeps publishing the target throughout. Issued right
        // after play(): the input thread processes RESUME then SET_TIME back-to-back, so the
        // flush path for a running input is the one taken.
        if let target = pausedSeekTargetMs {
            pausedSeekTargetMs = nil
            player.time = VLCTime(int: target)
        }
        // Start beats immediately so reportStart / cover-hide / the setRate re-apply aren't
        // gated on the resume readiness window. The resume seek runs concurrently (stored so
        // teardown() can cancel it); the poll holds beats until it lands, so there's no 0:00
        // flash. Mirrors AVKit's non-blocking play + detached seek-on-ready.
        // A pending resume offset means nothing on screen is worth drawing to yet.
        publish(positionMs: heldPositionMs)
        startProgressPolling()
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in await self?.seekToPendingStart() }
        // Deadline the load: if no first frame arrives (a truncated container the demuxer can't
        // finish, a dead SMB mount), surface a failure instead of an endless spinner. Disarmed by
        // the first beat (emitPosition/emitReady), teardown, or a terminal state.
        loadWatchdog.arm { [weak self] in self?.handleLoadTimeout() }
    }

    /// The source never opened within the watchdog deadline (a dead mount — VLC never left
    /// `.opening`). Surface `.failed` so the error scrim + offline-recovery take over. Stop the
    /// progress poll too: the app's `.failed` handler only sets `phase = .failed` (it does NOT tear
    /// the engine down — the user's exit/retry does), so a late beat from the wedged demux would
    /// otherwise flip `phase` back to `.playing` over the error. Guarded by `currentMedia` so a
    /// beat that already disarmed-then-this-somehow-raced is a no-op.
    private func handleLoadTimeout() {
        guard currentMedia != nil else { return }
        progressTask?.cancel()
        progressTask = nil
        continuation.yield(.failed(.assetNotPlayable))
    }

    /// A mid-playback stall the poll surfaced (frozen clock + frozen demux, see `startProgressPolling`)
    /// never recovered within the watchdog deadline — surface `.failed(.networkStalled)` so the
    /// "stream stalled and didn't recover" scrim + manual retry take over. Stop the poll too (mirrors
    /// `handleLoadTimeout`): the app's `.failed` handler only sets `phase = .failed` — it does NOT tear
    /// the engine down — so a late `.playing` beat from a briefly-recovering demux would otherwise flip
    /// `phase` back over the error scrim. Guarded by `currentMedia` so an already-torn-down engine no-ops.
    private func handleStallTimeout() {
        guard currentMedia != nil else { return }
        progressTask?.cancel()
        progressTask = nil
        continuation.yield(.failed(.networkStalled))
    }

    /// Resume by SEEKING to the saved offset once the demux reports seekable. This
    /// readiness window falls during buffering — before the first frame and while the
    /// loader cover is still up — so there's no 0:00 flash, and unlike the `:start-time`
    /// option the full timeline stays intact (scrubber spans the whole media, rewind
    /// before the resume point works). Mirrors AVKit's seek-on-ready resume.
    private func seekToPendingStart() async {
        guard let ms = pendingStartMs else { return }
        for _ in 0..<60 {  // up to ~3s, polling readiness every 50ms
            // currentMedia is nil'd by teardown(); bail so a dismiss mid-resume never
            // writes player.time on a stopped player.
            if Task.isCancelled || currentMedia == nil { return }
            if player.isSeekable {
                player.time = VLCTime(int: ms)
                pendingStartMs = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Never reported seekable in time; seek best-effort so resume isn't silently lost.
        guard !Task.isCancelled, currentMedia != nil else { return }
        player.time = VLCTime(int: ms)
        pendingStartMs = nil
    }

    /// The RESUMABLE mute, for a session that comes back: the engine-reusing transcode
    /// reload freezes the frame, silences, swaps the stream and plays again, and `play()`
    /// unmutes on the other side.
    ///
    /// What it does NOT do is cut audio that is already queued. Disassembly of the vendored
    /// VLCKit (libvlc 3.0.23) settles it: the iOS/tvOS aout module's `Open` installs a real
    /// hardware `MuteSet` (AudioOutputUnitStop + flush), and the inlined `aout_SoftVolumeInit`
    /// immediately overwrites `mute_set` with the soft-gain `aout_SoftMuteSet`. Mute is
    /// therefore a per-block gain applied at decode-enqueue time (`aout_DecPlay` →
    /// `aout_volume_Amplify`), which cannot reach the ~1-2s already sitting in the module's
    /// unbounded frame chain; that audio plays out regardless. `VLCAudio.volume = 0` is the
    /// same gain by another name. Muting still earns its keep: it stops every block that
    /// has not been enqueued yet, including while a blocked SMB read holds the input thread
    /// and delays the `pause()` below.
    ///
    /// For the terminal cut (exit) use `endAudio()`, the only render-level stop 3.x has.
    /// The exit latch is deliberately NOT set here: `play()` must still be able to unmute.
    /// The `pause()` below therefore always lands: only `endAudio()` raises the latch, only
    /// `load()` lowers it, and the one caller of `silence()` is the transcode reload, which
    /// runs while the session is live and never after an exit (the exit fence abandons reloads).
    public func silence() async {
        guard !refusedWhileWindingDown("silence") else { return }
        player.audio?.isMuted = true
        await pause()
    }

    /// The TERMINAL exit cut: audio stops here, at the render level, and stays stopped for
    /// the whole dismiss animation.
    ///
    /// `player.stop()` is the only thing in VLCKit 3.x that reaches audio already queued in
    /// the aout (see `silence()` for why mute cannot): it tears the audio output down
    /// rather than gaining it down. The mute still leads, because it costs nothing and
    /// stops the blocks that have not been enqueued yet, in case the stop takes a moment.
    ///
    /// **Off the MainActor by design.** `stop()` winds the input down, and on SMB that
    /// thread is routinely parked mid-network-read for seconds, so running it here would
    /// put that wait on the thread drawing the dismissal. libvlc is thread-safe; the
    /// engine's `@MainActor` pin exists for Swift 6's benefit (`VLCMediaPlayer` is not
    /// `Sendable`), not because libvlc demands main. `player.media` is deliberately NOT
    /// nil'd, same as `teardown()`: that is the `(p_md)` assertion crash.
    ///
    /// Detached but NOT fire-and-forget: the task is stored, and `teardown()`/`load()` join
    /// it before they drive the player again, so the stop never runs concurrently with the
    /// drawable/delegate/stop sequence on the way out.
    ///
    /// The latch is what makes it terminal: `play()` and `pause()` are both inert until the
    /// next `load()`, so neither a late resume nor a mid-dismiss scrubber grab can drive the
    /// player while this stop is still in flight on its own thread. The
    /// poll's own reassert reaches `player.play()` directly, so the play intent is dropped
    /// here too, and `.stopped` is outside `shouldReassertPlay`'s live states either way.
    /// `teardown()` stops again on the way out; libvlc's stop is idempotent.
    ///
    /// Idempotent by the latch: the close button ends audio and the presenter's dismissal
    /// fences again, and a second pass must not race a second stop against the first.
    public func endAudio() async {
        guard !audioEnded else { return }
        audioEnded = true
        desiredPlaying = false
        // Nothing left to time out or resume: a stopped input would trip the load/stall
        // watchdogs into a `.failed` beat under the outgoing UI, and the pending resume
        // seek would write a clock onto a dead player.
        loadWatchdog.disarm()
        stallWatchdog.disarm()
        resumeTask?.cancel()
        resumeTask = nil
        // The poll has nothing honest left to say about a stopped input: its inventory diff
        // would read the emptied track arrays as a change and publish a `.ready` with no
        // tracks at all, under a player that is already sliding away.
        progressTask?.cancel()
        progressTask = nil
        player.audio?.isMuted = true
        // Detach the delegate BEFORE the stop: a main-queue `mediaPlayerStateChanged` would
        // otherwise read `player.state` while the detached stop drives the same player.
        // `load()` re-attaches it for the engine-reusing transcode reload.
        player.delegate = nil
        scheduleDetachedStop()
    }

    /// Joins the detached stop and drops the reference. The choke point every path that
    /// touches the player after an exit cut goes through (`teardown()`, `load()`) so the stop
    /// is never in flight while the MainActor drives the same player.
    ///
    /// Loops on identity rather than clearing unconditionally: the await is a suspension, and
    /// a SECOND stop can be assigned during it (a dismissal fence firing while `teardown()`
    /// waits on `endAudio()`'s). Nil'ing whatever is there when the first one returns
    /// discarded that task un-awaited and walked straight into the drawable/delegate/stop
    /// sequence with it still running — the exact crash this latch exists to prevent.
    func awaitPendingStop() async {
        while let task = pendingStopTask {
            await task.value
            guard pendingStopTask == task else { continue }
            pendingStopTask = nil
        }
    }

    /// The position the progress bar is currently SHOWING, which is not `clockMs` whenever a
    /// gate is holding the raw clock back: the resume-seek hold (`pendingStartMs`), the
    /// rate-flush bridge (`rateFlushAnchorMs`), or a user seek still settling
    /// (`pendingSeekMs`, whose extrapolation is what the poll has been publishing).
    ///
    /// Right after `setTime` libvlc keeps reporting the PRE-seek clock for seconds (see
    /// `pendingSeekMs`), so a pause landing inside that hold published a position 15s behind a
    /// 01:00 → 01:15 scrub: the progress dot jumped backwards, and the Now Playing position and
    /// the throttled resume-point save persisted the wrong offset until the next resume
    /// corrected it. Pause must publish what the bar is showing, never the stale clock.
    private var heldPositionMs: Int32 {
        Self.heldPositionMs(
            pendingStartMs: pendingStartMs,
            rateFlushAnchorMs: rateFlushAnchorMs,
            pendingSeekMs: pendingSeekMs,
            pendingSeekPolls: pendingSeekPolls,
            pollMs: Self.pollIntervalMs,
            rate: desiredRate,
            durationMs: effectiveDurationMs(),
            clockMs: clockMs
        )
    }

    /// Where the position of the beat about to ship comes from (see `PositionProvenance`).
    ///
    /// The two holds that make `heldPositionMs` return something other than `clockMs` because
    /// a SEEK is unresolved — a resume offset that hasn't been applied yet, a user seek still
    /// settling — are precisely the windows where the published position is a target echo or an
    /// extrapolation off one, i.e. `.projected`. With neither up, the raw clock IS the beat:
    /// `.observed`.
    ///
    /// `.stale` never appears on this engine, and that is a property of `heldPositionMs` rather
    /// than a claim about libvlc's clock: while any hold stands, every emitting path publishes
    /// the held value, so the lying pre-seek clock is suppressed instead of labelled. The paths
    /// that publish the raw clock during a seek window — an expired hold releasing, or the
    /// abandon cap ending one — clear `pendingSeekMs` first (`seekHoldShouldRelease`), so by
    /// the time the clock reaches the wire there is no seek of ours outstanding to make it
    /// anything but observed.
    ///
    /// **`rateFlushAnchorMs` is deliberately NOT here**, though it does hold `heldPositionMs`.
    /// A speed change is not a seek: the anchor is the CURRENT clock frozen while the re-decode
    /// runs, so the position is exactly where the media is — observed, and display-safe by
    /// construction. Labelling it `.projected` made every 1.25× tap read to the app as an
    /// unresolved seek, which skips the stall debounce and threw the scrim up on the spot.
    /// It stays in `heldPositionMs`'s precedence: the question there is "which value ships",
    /// not "is this a guess".
    ///
    /// Not in the list either: `pausedSeekTargetMs` and `reanchorFlushMs`. Both are *aout
    /// re-issue* latches — they say the audio pipeline still owes a flush, not that the
    /// position is a guess — and both are armed alongside a `pendingSeekMs` that already
    /// covers the window where it is.
    private var provenanceNow: PositionProvenance {
        pendingSeekMs == nil && pendingStartMs == nil ? .observed : .projected
    }

    public func pause() async {
        // Same terminal latch `play()` reads, for the same session. The HUD calls
        // `engine?.pause()` directly (the iOS drag begin, the tvOS reducer's `.pause`
        // effect) and the outgoing player stays mounted and hit-testable for the whole
        // dismissal, so a scrubber grabbed mid-slide-out would command `player.pause()` on
        // the MainActor while `endAudio()`'s detached `player.stop()` is still winding the
        // same non-Sendable player down. A pure early return is the whole fix: the session
        // is terminal, `endAudio()` already cleared `desiredPlaying`, and there is no beat
        // left worth publishing under a dismissing UI.
        guard Self.shouldHonorTransport(audioEnded: audioEnded),
              !refusedWhileWindingDown("transport") else { return }
        desiredPlaying = false
        player.pause()
        // An explicit pause is never a stall: drop any frozen run and cancel a pending stall failure
        // (the poll is `isPlaying`-gated so it won't observe while paused, but a stall in flight must
        // not fire the 45s failure on a deliberately-paused player).
        stallDetector.reset()
        isStalled = false
        stallWatchdog.disarm()
        reassertTicks = 0
        // Emit the paused beat immediately rather than waiting for the next poll (which
        // stays silent while paused) so the transport button flips at once. `player.isPlaying`
        // can lag a frame after pause(), so force isPlaying: false. The position is the HELD
        // one, not the raw clock: a pause inside a settle hold would otherwise republish the
        // pre-seek clock and jump the dot backwards (see `heldPositionMs`).
        emitPosition(isPlaying: false, positionMs: heldPositionMs)
    }

    public func setRate(_ rate: Float) async {
        guard !refusedWhileWindingDown("setRate") else { return }
        // Store the intent so the progress poll re-asserts it once playing (libvlc drops a rate
        // set before the input is live — the fresh-engine re-apply right after play()).
        let rateChanged = Self.shouldReassertRate(current: player.rate, desired: rate)
        desiredRate = rate
        player.rate = rate
        // A live rate change otherwise stays inaudible until the old-rate buffer drains
        // (≈ network-caching). Flush in place so VLC re-decodes at the new rate now; the poll
        // bridges the brief re-buffer as buffering, not a frozen clock.
        if rateChanged { flushForImmediateRate() }
    }

    /// Force a just-changed `rate` to take effect promptly by re-decoding from the current
    /// position — a seek-in-place flushes the already-decoded old-rate buffer that would
    /// otherwise play out first (the ~3s "speed applies late" lag, proven ≈ `network-caching`).
    /// The re-decode briefly re-buffers; `startProgressPolling` publishes buffering beats at the
    /// hold point (debounced — invisible if quick, a spinner only if it runs long) until the clock
    /// advances past it, instead of a silently frozen counter. Clean at 3000ms (no pixelation,
    /// the same buffer that keeps a 2× seek clean), unlike the 1000ms shrink we reverted.
    private func flushForImmediateRate() {
        // Skip during initial load / resume (would seek off the resume point before it applies)
        // and while a user seek is still settling (that seek already re-filled at this rate).
        guard player.isPlaying, pendingStartMs == nil, pendingSeekMs == nil else { return }
        let pos = clockMs
        guard pos > 0 else { return }
        rateFlushAnchorMs = pos
        rateFlushTicks = 0
        player.time = VLCTime(int: pos)
    }

    /// Push the user's chosen speed onto the live player if it has drifted (libvlc applies
    /// `rate` to the active input, so a rate chosen before the input existed never took). The
    /// `shouldReassertRate` epsilon gate keeps this a no-op once matched. Called from both the
    /// flush-bridge hold and the live-input poll pass — one place so the policy can't diverge.
    private func reassertRateIfNeeded() {
        if Self.shouldReassertRate(current: player.rate, desired: desiredRate) {
            player.rate = desiredRate
        }
    }

    /// Push the user's subtitle delay back onto the live input if it has drifted. Same
    /// command-drop family as `reassertRateIfNeeded()`: `currentVideoSubTitleDelay` is scoped
    /// to the ACTIVE INPUT, so libvlc can drop a write issued before the input was up.
    ///
    /// Skipped entirely on a `:no-spu` asset: with the SPU renderer off there is no
    /// subtitle input variable to converge on, so the readback never matches and the
    /// write is re-issued on every 500 ms tick, forever, for nothing.
    private func reassertSubtitleDelayIfNeeded() {
        guard !engineSubtitlesDisabled else { return }
        let desiredUs = desiredSubtitleDelayMs * 1000
        if player.currentVideoSubTitleDelay != desiredUs {
            player.currentVideoSubTitleDelay = desiredUs
        }
    }

    /// **Seek-settle contract (see `PlaybackEngine.seek(to:)`).** VLC's `.observed` is the
    /// strong form: it means libvlc's own clock converged on the target (±3s, see
    /// `seekHasConverged`), not merely that a call returned. Every beat from here until then is
    /// `.projected` — the `seek()` echo below, the hold's extrapolations, its starvation
    /// `.buffering`, and any `pause()` landing inside the window — because the engine publishes
    /// the HELD value on all of them (`heldPositionMs`), never the clock that is still lying.
    /// That is why no VLC beat is ever `.stale`: the stale reading is suppressed, not shipped.
    /// A hold that spends its poll budget releases onto the raw clock as `.observed` — but only
    /// once that clock has moved off the pre-seek value, so an expiring seek can never label
    /// the position it seeked AWAY from as a landing (`seekHoldShouldRelease`). The 15s abandon
    /// cap under that (`seekHoldAbandoned`) is the one release that does not test the clock at
    /// all: the engine has given up, and what it publishes from then on is whatever libvlc
    /// really reads — honest, `.observed`, and never frozen on a guess for the rest of the
    /// session.
    public func seek(to time: CMTime) async {
        guard !refusedWhileWindingDown("seek") else { return }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        // Capture the play/pause intent BEFORE the seek: libvlc transiently reports
        // `isPlaying == false` while the demux re-buffers right after `setTime`, so reading
        // it for the beat below emitted a phantom `.paused` (transport glyph flashed). A seek
        // doesn't change whether the user is playing. (Note: the drag-scrub pauses the engine
        // itself before seeking — that path is handled in the controls, not here.)
        let wasPlaying = player.isPlaying
        // A user seek supersedes a still-pending resume seek: cancel the resume
        // task and clear the saved offset so an in-flight seekToPendingStart()
        // can't overwrite this position with the stale resume point during the
        // ~3s readiness window.
        resumeTask?.cancel()
        pendingStartMs = nil
        // A user seek supersedes an in-flight rate-flush bridge: clear its anchor so the poll
        // doesn't keep republishing the stale pre-seek hold position. This seek's own
        // `pendingSeekMs` gate (below) now drives the settle; the rate stays re-asserted by the
        // poll's live-input pass once the seek lands.
        rateFlushAnchorMs = nil
        // A user seek is a fresh intent and re-reads the demux out of order: clear any stall run so
        // the post-seek byte jump can't be misread, and cancel a pending stall failure (seeking out
        // of a frozen frame is recovery).
        stallDetector.reset()
        isStalled = false
        stallWatchdog.disarm()
        reassertTicks = 0
        let ms = Self.clampSeekMs(seconds: seconds)
        // `VLCTime(int: 0)` builds a NULL time (the initializer drops a zero), but the
        // `time` setter reads it as `[[value value] longLongValue]` — nil messages to 0 —
        // so a rewind-to-start still seeks to 0. Only reads have to distinguish the two;
        // see `clockMs`.
        // Sampled BEFORE the write, and the order is the whole correctness argument. The
        // hold's give-up compares the live clock against this to tell "libvlc republished at
        // the new offset" from "libvlc is still reporting where the seek started" — the latter
        // must never ship as a landing (`seekHoldShouldRelease`). Read AFTER the write it
        // happens to be right only because 3.x's getter is a cache the input refreshes, so the
        // target is not visible through it yet; that is libvlc's timing, not a guarantee, and
        // a build whose cache takes the request would record the TARGET as the pre-seek clock
        // — a value the comparison can never match, releasing onto the stale clock every time.
        preSeekClockMs = Self.validClockMs(player.time)
        player.time = VLCTime(int: ms)
        // Gate the poll until VLC's clock settles on this target so its transient
        // post-seek reads can't surface as an overshoot (see pendingSeekMs).
        pendingSeekMs = ms
        pendingSeekPolls = 0
        seekHoldTotalPolls = 0   // a fresh intent gets the full abandon budget
        seekHoldReadBytes = 0
        // A playing seek flushes the aout natively; a paused one does not on VLCKit 3.x —
        // arm the resume-time in-place re-issue (see pausedSeekTargetMs). Overwrites any
        // older latch so the newest target always wins.
        pausedSeekTargetMs = wasPlaying ? nil : ms
        // Publish the new position now so the scrubber tracks the seek instead of
        // snapping back to the last polled position on release. Carry the pre-seek intent
        // so a playing seek stays `.playing` (no phantom paused glyph).
        emitPosition(isPlaying: wasPlaying, positionMs: ms)
    }

    /// 3.x selects by writing the libvlc track id onto `currentAudioTrackIndex` (the id
    /// comes straight back out of `audioTrackIndexes`, so no lookup is needed); the
    /// parallel index/name arrays are the whole selection API. The id is still validated
    /// against the live inventory so a stale menu selection from a previous item can't
    /// write a bogus index onto the current input.
    public func setAudioTrack(_ track: AudioTrack) async {
        guard !refusedWhileWindingDown("setAudioTrack") else { return }
        guard let vlcID = Self.trackIndex(from: track.id),
              audioDescriptors().contains(where: { $0.id == vlcID }) else { return }
        player.currentAudioTrackIndex = vlcID
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) async {
        guard !refusedWhileWindingDown("setSubtitleTrack") else { return }
        guard let track else {
            subtitlesDisabled = true
            player.currentVideoSubTitleIndex = Self.disabledTrackIndex
            return
        }
        // The asset draws its own text subtitles; selecting an engine track would render a
        // second copy THROUGH the client overlay. `:no-spu` already blinds libvlc's renderer,
        // so honouring this would only desynchronize the latch from what is on screen.
        guard !engineSubtitlesDisabled else {
            Self.log.info("setSubtitleTrack ignored: this asset renders subtitles client-side")
            return
        }
        guard let vlcID = Self.trackIndex(from: track.id),
              subtitleDescriptors().contains(where: { $0.id == vlcID }) else { return }
        subtitlesDisabled = false
        player.currentVideoSubTitleIndex = vlcID
        await reshowCueAtCurrentPosition()
    }

    /// Re-emit the cue that is active RIGHT NOW after a track selection.
    ///
    /// libvlc demuxes only selected elementary streams, so the cue already on screen when
    /// the user picks a track was read and dropped before the ES existed: nothing appears
    /// until the next dialogue line (AVKit has no such gap). A seek is what puts it back.
    /// VLC 3.0's MKV demuxer indexes EVERY subtitle block as its own seekpoint
    /// (`matroska_segment.cpp`, the `SPU_ES` branch of `BlockGetHandler_l3`), and `Seek()`
    /// rewinds each ES the es_out reports as SELECTED to its greatest seekpoint ≤ the
    /// target (`i_skip_until_fpos`) — so a seek issued AFTER the write re-reads the active
    /// cue's block. The SPU decoder then exempts it from the accurate-seek preroll drop
    /// ("Preroll does not work very well with subtitle", `src/input/decoder.c`), which is
    /// what makes it draw rather than get swallowed for being older than the seek target.
    ///
    /// Through the engine's own `seek(to:)`, not a bare `setTime`: that is what keeps the
    /// position beat labelled, the settle hold armed, and — when the engine is paused —
    /// the aout flush latch armed the way a user seek's is.
    ///
    /// **This costs a re-buffer**: an audible/visible hiccup on every subtitle switch, the
    /// same one any seek makes on this path. `currentTime` is `.invalid` before the first
    /// frame and for the whole resume-seek window (exactly where a re-seek would fight the
    /// resume), so that gate is the precondition rather than an extra latch.
    private func reshowCueAtCurrentPosition() async {
        let time = currentTime
        guard currentMedia != nil, time.isValid else { return }
        await seek(to: time)
    }

    public func debugSnapshot() async -> PlaybackDebugInfo {
        var info = PlaybackDebugInfo()

        let size = player.videoSize
        if size.width > 0, size.height > 0 {
            info.presentationWidth = Int(size.width)
            info.presentationHeight = Int(size.height)
        }

        let audio = audioDescriptors()
        let subtitles = subtitleDescriptors()
        info.selectedAudible = audio.first(where: { $0.id == player.currentAudioTrackIndex })?.name
        info.legibleOptions = subtitles.map(\.name)
        info.selectedLegible = subtitles.first(where: { $0.id == player.currentVideoSubTitleIndex })?.name

        // The REQUESTED delay, not `player.currentVideoSubTitleDelay`: that libvlc variable is
        // input-scoped and reads 0 again after a reload, which would contradict the number
        // the HUD is showing. (A non-nil value is how the HUD knows to offer the ± nudge.)
        info.subtitleDelayMs = desiredSubtitleDelayMs

        return info
    }

    /// VLC retimes subtitles live (microsecond-precision). Used by the HUD to
    /// diagnose / work around the segmented-WebVTT desync on the AVKit path by
    /// proving the SRT itself is correctly timed under VLC.
    ///
    /// The intent is persisted, not just written: `currentVideoSubTitleDelay` is an
    /// input-scoped libvlc variable, so a write issued before the input was up is dropped.
    /// The poll re-asserts it, same shape as `reassertRateIfNeeded()` — but only for the
    /// media it was set against. A `load()` resets it; re-applying across a reload is the
    /// app's job, because only the app knows whether the fresh media is the same item.
    public func setSubtitleDelay(milliseconds: Int) async {
        guard !refusedWhileWindingDown("setSubtitleDelay") else { return }
        desiredSubtitleDelayMs = milliseconds
        player.currentVideoSubTitleDelay = milliseconds * 1000
    }

    /// Teardown order: detach drawable → nil delegate → stop → finish.
    ///
    /// **`player.media` is deliberately NOT nil'd.** Clearing the media while libvlc is
    /// still winding the input down is the shape that aborted on device with
    /// `Assertion failed: (p_md)` (media.c) — libvlc's own teardown path retains the
    /// media without a null check, so a race between our nil-write and its release
    /// crashes rather than no-ops. Leaving the media set keeps every getter valid; the
    /// player releases it on dealloc once the engine and the video host's coordinator
    /// both drop their references. Detaching the drawable first also stops the vout.
    public func teardown() async {
        desiredPlaying = false
        // Join `endAudio()`'s detached stop before anything below drives the player:
        // the drawable/delegate/stop sequence and that stop share one non-Sendable
        // `VLCMediaPlayer`, and running them on two threads is the crash shape.
        await awaitPendingStop()
        loadWatchdog.disarm()
        stallWatchdog.disarm()
        progressTask?.cancel()
        progressTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        // A still-waiting captureFrame continuation must not outlive the player: resume
        // it as a failure before nil'ing the delegate (which would otherwise strand it).
        completeSnapshot(success: false)
        pendingSeekMs = nil
        preSeekClockMs = nil
        seekHoldTotalPolls = 0
        pausedSeekTargetMs = nil
        reanchorFlushMs = nil
        rateFlushAnchorMs = nil
        publish(positionMs: -1)
        player.drawable = nil
        player.delegate = nil
        // Off the MainActor for the same reason `endAudio()` is — and `endAudio()`'s stop only
        // covers the paths that run it, not a load failure, a reactive engine swap, or a
        // `.failed` retry. Awaited through the joinable latch, so the MainActor is released
        // for the duration while `isWindingDown` keeps every other entry point inert.
        scheduleDetachedStop()
        await awaitPendingStop()
        currentMedia = nil
        continuation.finish()
    }

    /// Still-frame grab for SMB thumbnail backfill: asks libvlc for a PNG snapshot of the
    /// live decode surface (no second network open), then re-encodes to HEIC so the app
    /// cache can store the bytes under its current `.heic` extension. Best-effort: any
    /// failure (nothing loaded, timeout, empty file, encode error) returns nil and never
    /// perturbs playback. VLC's snapshot API is fire-and-forget + `mediaPlayerSnapshot`
    /// notification — bridged here with a checked continuation raced against a 5s timeout;
    /// the nil-out-after-resume pattern makes a double-resume impossible.
    public func captureFrame() async -> Data? {
        guard !refusedWhileWindingDown("captureFrame") else { return nil }
        guard currentMedia != nil else { return nil }

        // Unique temp path per capture — VLC writes PNG regardless of extension, but the
        // suffix keeps the file recognizable in a crash dump / leftover-temp scan.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        // If a previous capture is somehow still pending (shouldn't happen — the app
        // schedules one backfill per session), fail it first so its continuation can't
        // race this one's resume.
        completeSnapshot(success: false)

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            snapshotContinuation = continuation
            snapshotExpectedPath = path.path
            snapshotTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                // Hop to MainActor: the timeout Task is unstructured and may resume off-main;
                // completeSnapshot mutates MainActor-isolated state.
                await self?.completeSnapshot(success: false)
            }
            // Fixed height, width 0: the vendored VLCMediaPlayer.h documents "If width OR
            // height is 0, original aspect-ratio is preserved" — libvlc itself hands back a
            // browse-tile-scale PNG instead of a full source-resolution one this method
            // would otherwise have to decode+downscale on top of. 320 is the tier both browse
            // thumbnailers emit (`VLCThumbnailer`'s `height: 320` default, `AVThumbnailer`'s
            // `targetHeight`); a backfilled still shares their cache and its ~30–120 KB per
            // HEIC budget, which a 1280 frame blows by 5–10×.
            player.saveVideoSnapshot(at: path.path, withWidth: 0, andHeight: 320)
        }

        // Immediate best-effort cleanup, with a delayed second pass behind it (see
        // `scheduleCleanup`) — libvlc's write isn't bounded by our timeout, so a capture that
        // timed out here can still land on disk moments later.
        defer { Self.scheduleCleanup(at: path) }
        guard succeeded else { return nil }
        // Reading + decoding the PNG and re-encoding it as HEIC is real CPU work for a
        // full frame; `captureFrame()`'s contract (`PlaybackEngine.swift`) says it must
        // never stall playback, and this whole engine is pinned to `@MainActor` — so the
        // work has to run off-actor. `Data`/`CGImage` are Sendable.
        return await Self.decodeAndEncode(pngAt: path)
    }

    /// Decodes the PNG at `path` and re-encodes it as HEIC, entirely off the main actor via a
    /// detached task. Long-edge-capped at 320: the snapshot is already 320 tall (see
    /// `captureFrame()`), but a very wide source's width can still exceed that, and this is the
    /// tier AVKitEngine and both browse thumbnailers share. `nonisolated` because none of this
    /// touches VLC or actor state — it's pure ImageIO work. ImageTranscode falls back to JPEG when
    /// the host has no HEVC encoder (simulator).
    private nonisolated static func decodeAndEncode(pngAt path: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let pngData = try? Data(contentsOf: path), !pngData.isEmpty else { return nil }
            guard let cgImage = ImageTranscode.downscaledImage(from: pngData, maxPixelSize: 320) else {
                return nil
            }
            return try? ImageTranscode.encodeHEIC(cgImage)
        }.value
    }

    /// Removes the temp snapshot at `path` now, then again after a delay. libvlc's snapshot write
    /// is fire-and-forget and can land AFTER a timed-out `captureFrame()` already gave up and ran
    /// its immediate cleanup — without the delayed pass that late write leaks a tmp PNG forever.
    private nonisolated static func scheduleCleanup(at path: URL) {
        try? FileManager.default.removeItem(at: path)
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(10))
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Resume-once for the snapshot continuation. Nil's the stored continuation BEFORE
    /// `resume` so a late timeout (or a second `mediaPlayerSnapshot`) is a no-op rather
    /// than a double-resume crash. Also cancels the racing timeout task.
    private func completeSnapshot(success: Bool) {
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        snapshotExpectedPath = nil
        guard let continuation = snapshotContinuation else { return }
        snapshotContinuation = nil
        continuation.resume(returning: success)
    }

    // MARK: - Private helpers

    /// Demux/network buffer depth (ms). 3000 is AV1-software-decode runway: shrinking it
    /// to 1000 to ease rate changes backfired — at 2× a far seek empties the buffer and
    /// AV1 decode can't refill 1000ms (= 500ms wall-clock at 2×) before the vout starves
    /// → macroblocked playback until it catches up (device-proven; see git history). That
    /// constraint is DECODE-bound, not network-bound, so it stays for software codecs and
    /// unknown codecs; a live rate change applies promptly via `flushForImmediateRate`
    /// instead. A hardware-decoded codec (h264/hevc → VideoToolbox) on a LAN SMB share
    /// refills faster than realtime — a shallower buffer there just makes seeks land sooner.
    nonisolated static func cacheDepthMs(for hints: PlaybackHints) -> Int {
        let hardwareDecoded: Set<VideoCodec> = [.h264, .hevc]
        return (hints.scheme == "smb" && hints.videoCodec.map(hardwareDecoded.contains) == true)
            ? 1500 : 3000
    }

    private func applyOptions(to media: VLCMedia, asset: PlayableAsset) {
        for option in Self.mediaOptions(for: asset) {
            media.addOption(option)
        }
    }

    /// Every libvlc media option this asset gets, in application order. Pure so the option
    /// STRINGS — the part libvlc silently ignores when they are wrong — are testable without
    /// a live decode. **Never log the result**: the tail carries `vlcOptions`, which can hold
    /// SMB credentials.
    nonisolated static func mediaOptions(for asset: PlayableAsset) -> [String] {
        var options = [":network-caching=\(cacheDepthMs(for: asset.hints))"]
        // The app renders every text subtitle itself, so libvlc's SPU renderer must be blind
        // for the whole input — not merely deselected once the app gets around to it. VLC
        // auto-selects a default/forced embedded text track as the demux discovers it, and
        // 3.x has no track-selection delegate, so without this the only enforcement is the
        // 500ms poll re-assert (kept as the backstop) and a late track renders THROUGH the
        // overlay until the next tick.
        if asset.engineSubtitlesDisabled {
            options.append(":no-spu")
        }
        // libass (ASS/SSA) and the simple freetype renderer (SRT / plain `text`) are separate
        // subsystems with separate options AND DIFFERENT VALUE SEMANTICS: `ssa-fontsdir` is a
        // DIRECTORY libass scans, `freetype-font` is a font FAMILY NAME ("Font family for the
        // font you want to use" — libvlc 3.0's freetype module). Handing the latter a file
        // path is a silent no-op that falls back to the module's hardcoded Helvetica Neue, so
        // the app passes the family it registered the face under.
        if let fontsDirectory = asset.subtitleFontsDirectory?.path {
            options.append(":ssa-fontsdir=\(fontsDirectory)")
        }
        if let fontFamily = asset.subtitleFontFamily {
            options.append(":freetype-font=\(fontFamily)")
        }
        // VLC's freetype renderer (embedded plain-text subs), pinned to the boxless
        // black-outline look of `SubtitleStyle.standard`. The fill dim is the real
        // change — the default 0xFFFFFF reads as peak white next to tone-mapped HDR
        // video. Background/outline match VLC's *desktop* defaults, but are set
        // explicitly because the iOS build's defaults have never been device-verified
        // (a dim fill WITHOUT a border would be worse than the old pure white).
        // ASS/SSA keep their authored styles (libass ignores freetype-*).
        options.append(":freetype-color=\(SubtitleStyle.standard.foreground.rgb24)")
        options.append(":freetype-background-opacity=0")
        options.append(":freetype-outline-color=\(SubtitleStyle.standard.outline.rgb24)")
        options.append(":freetype-outline-thickness=4")
        if let headers = asset.headers {
            // Header values originate from the trusted Jellyfin server response and
            // are interpolated verbatim into VLC option strings (no delimiter sanitization).
            if let ua = headers["User-Agent"] {
                options.append(":http-user-agent=\(ua)")
            }
            if let ref = headers["Referer"] {
                options.append(":http-referrer=\(ref)")
            }
        }
        // Caller-supplied verbatim media options (e.g. SMB credentials). Opaque to
        // the engine and applied last so they can override the defaults above.
        // NEVER logged — an entry here can carry a password.
        options.append(contentsOf: asset.vlcOptions ?? [])
        return options
    }

    /// Progress poll cadence (ms), matching `AVKitEngine`'s periodic observer. Named because
    /// it is also the seek hold's clock: `seekHoldPositionMs` derives elapsed time from the
    /// tick count rather than a wall-clock read, so the two must not drift apart.
    nonisolated static let pollIntervalMs = 500

    /// Poll the live player clock every `pollIntervalMs` (matching `AVKitEngine`'s observer
    /// cadence) and publish a `.playing` beat while playback is active. Stays silent
    /// while paused — pause/seek emit their own beat — so a paused stream doesn't
    /// flood progress reports, exactly like AVKit's periodic observer (which doesn't
    /// fire while time is frozen).
    private func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.pollIntervalMs))
                // `try?` swallows the sleep's cancellation error, so without this the loop
                // runs ONE more full iteration after `endAudio()`/`teardown()` cancelled it
                // and emits a stale beat from a stopping player. A cancelled poll says nothing.
                if Task.isCancelled { return }
                guard let self else { return }
                // Re-assert the no-engine-subtitle latch every tick. VLC can SELECT a
                // late-discovered embedded text track at any point during the demux. If the app is
                // drawing its own sidecar (or subs are Off), force the engine subtitle back off so
                // it can't render THROUGH the overlay. 3.x has no track-selection delegate at all,
                // so this tick IS the only enforcement path — self-healing within one tick. Runs
                // FIRST so the rate-flush bridge's `continue` can't starve it for the hold (a
                // re-decode can silently re-select an embedded track during that window).
                if self.mustSuppressEngineSubtitles,
                   self.player.currentVideoSubTitleIndex != Self.disabledTrackIndex {
                    self.player.currentVideoSubTitleIndex = Self.disabledTrackIndex
                }
                // Re-emit `.ready` when the track picture or the container length changes.
                // 3.x reports neither through a delegate, so the poll is where a late embedded
                // text track, VLC's stable default selection, and a length that only resolves
                // once the demux has run all become visible. Also runs before the gates below,
                // so a still-settling seek can't defer the menus.
                self.publishInventoryIfChanged()
                // Rate-change flush bridge: while VLC re-decodes at the new rate its clock holds at
                // the flush point and it transiently reports not-playing. Surface that as buffering
                // (the app debounces it — invisible if quick, a spinner only if it runs long)
                // instead of a silently frozen counter, re-asserting the rate so the re-decode runs
                // at the new speed, and resume once the clock advances past the hold (or the budget
                // elapses). Runs before the isPlaying guard because the re-decode reports not-playing.
                if let anchor = self.rateFlushAnchorMs {
                    self.rateFlushTicks += 1
                    self.reassertRateIfNeeded()
                    if Self.flushBridgeShouldResume(now: self.clockMs, anchor: anchor, ticks: self.rateFlushTicks) {
                        self.rateFlushAnchorMs = nil
                    } else {
                        self.emitBuffering(positionMs: anchor)
                        continue
                    }
                }
                // Play-intent reassert: a resume can be dropped while the input thread is
                // blocked mid-read (the scrub commit's play() right after a paused seek on a
                // high-RTT share) — the input then stays paused forever behind a playing UI,
                // because this poll is `isPlaying`-gated and emits nothing. Re-push the intent
                // until the input obeys; play() on an already-playing input is a libvlc no-op,
                // and the state gate keeps a finished/error/opening input untouched.
                if Self.shouldReassertPlay(desiredPlaying: self.desiredPlaying,
                                           isPlaying: self.player.isPlaying,
                                           state: self.player.state) {
                    // Treat the reassert run as a stall: log ONCE per run (this branch also
                    // matches ordinary initial buffering, where per-tick .info would spam a
                    // wedge claim over a normal cold start) and arm the stall watchdog so a
                    // PERMANENTLY dropped resume escalates to .failed(.networkStalled) instead
                    // of an eternal spinner — everything below the isPlaying guard (including
                    // the honest-stall arming) is unreachable while the input stays paused.
                    // Recovery disarms via the existing isStalled clear once beats resume;
                    // initial loads stay bounded by the (shorter) loadWatchdog either way.
                    if !self.isStalled {
                        self.isStalled = true
                        self.stallWatchdog.arm()
                        Self.log.info("play-intent reassert: input paused against play intent, re-issuing play()")
                    }
                    self.player.play()
                    // Escalation: on device a post-scrub input can wedge with VideoToolbox
                    // refusing post-seek timestamps ("Could not convert timestamp" +
                    // pic_holder_wait timeouts) — play() alone never unwedges it, but a fresh
                    // seek does (the manual scrub "nudge" users discovered). After ~3s of
                    // futile reasserts, re-anchor the input at the held position: setTime
                    // flushes the pipeline and restarts the decoder exactly like a user seek.
                    // Periodic (every 6 ticks), not one-shot — a still-wedged input keeps
                    // getting nudged until the stall watchdog bounds the session.
                    //
                    // Held position only, never a synthesized one: this branch ALSO matches
                    // ordinary cold-start buffering (see the log note above), where the clock
                    // is still invalid and a resume seek may not have applied yet. Escalating
                    // there would re-anchor at a made-up 0 — flushing a healthy fill and
                    // destroying the resume point — so the nudge requires a real anchor (an
                    // in-flight user seek or a valid clock) and stands down while the resume
                    // offset is still pending.
                    self.reassertTicks += 1
                    if self.reassertTicks % 6 == 0, self.pendingStartMs == nil,
                       let anchor = self.pendingSeekMs ?? Self.validClockMs(self.player.time) {
                        Self.log.warning("play-intent reassert escalation: re-anchoring input at \(anchor)ms")
                        // Before the write, for the reason spelled out in `seek(to:)`.
                        self.preSeekClockMs = Self.validClockMs(self.player.time)
                        self.player.time = VLCTime(int: max(0, anchor))
                        self.pendingSeekMs = max(0, anchor)
                        // `pendingSeekPolls` restarts (it is the extrapolation's clock, and the
                        // anchor is fresh) but `seekHoldTotalPolls` deliberately does NOT: this
                        // fires every 6 ticks, so resetting the abandon budget here would let a
                        // permanently wedged input hold the bar for the whole session.
                        self.pendingSeekPolls = 0
                        self.seekHoldReadBytes = 0
                        self.reanchorFlushMs = max(0, anchor)
                    }
                    // A wedged post-seek resume IS a stall at the target: surface it as
                    // (VM-debounced) buffering there instead of a frozen frame under a
                    // playing glyph. Only when a user seek is in flight — a wedge with no
                    // seek pending has no meaningful hold point to pin the bar to.
                    if let target = self.pendingSeekMs {
                        self.emitBuffering(positionMs: target)
                    }
                } else {
                    self.reassertTicks = 0
                }
                guard Self.shouldRunLiveTick(desiredPlaying: self.desiredPlaying,
                                             isPlaying: self.player.isPlaying) else { continue }
                // Re-assert the playback rate now the input is live. libvlc applies `rate` to
                // the active input, so the speed chosen before the demux was up (the
                // fresh-engine re-apply right after play()) was dropped — this is where it sticks.
                self.reassertRateIfNeeded()
                // Same story for the subtitle delay: it is input-scoped, so a reload drops it.
                self.reassertSubtitleDelayIfNeeded()
                // A reassert-escalation re-anchor was issued while the input was stuck
                // paused — the unflushed-aout shape of a paused user seek. The input runs
                // now (this is the live tick), so re-issue it once: same position, and the
                // recovered picture no longer sits over the pre-seek soundtrack.
                if let target = self.reanchorFlushMs {
                    self.reanchorFlushMs = nil
                    self.player.time = VLCTime(int: target)
                }
                // Hold beats until the resume seek has applied, so the first beat reports
                // the resume position rather than the pre-seek clock (no 0:00 flash).
                guard self.pendingStartMs == nil else { continue }
                // ONE sample of each honest signal per tick, taken ABOVE every hold. Two
                // reasons: the stall detector has to see every poll (a seek in flight does not
                // suspend a network death, and the hold's own `continue` used to hide those
                // ticks from it), and the hold's `seekHoldAction` compares the demux counter
                // against the previous tick's — sampling it twice in one tick compares it
                // against itself.
                let nowMs = self.clockMs
                let readBytes = self.demuxReadBytes
                // `stallDetector` OWNS `isStalled`/`stallWatchdog` from here down; the hold
                // branches below decide only what to PUBLISH and never touch the flag. They
                // used to disarm it on every healthy tick, which silently cancelled a stall
                // armed by the play-intent reassert branch (the device-observed VideoToolbox
                // post-scrub wedge) — a seek committed into a dying share then lost its 45s
                // failure and buffered forever.
                let stalled = self.stallDetector.observe(timeMs: nowMs, readBytes: readBytes)
                if stalled, !self.isStalled {
                    self.isStalled = true
                    self.stallWatchdog.arm()   // bound the stall — expiry → .failed(.networkStalled)
                }
                // Suppress the transient clock VLC reports right after a user seek until it
                // converges on the requested target (±3s tolerates a keyframe-snapped
                // landing); a ~5s fallback resumes live tracking if it never lands exactly —
                // unless the clock is still reading its pre-seek value, in which case
                // releasing would publish that stale clock as a landing — and a hard 15s
                // abandon cap under both (`seekHoldShouldRelease`).
                if let target = self.pendingSeekMs {
                    self.pendingSeekPolls += 1
                    self.seekHoldTotalPolls += 1
                    if Self.seekHoldShouldRelease(now: nowMs, target: target,
                                                  polls: self.pendingSeekPolls,
                                                  totalPolls: self.seekHoldTotalPolls,
                                                  preSeekClockMs: self.preSeekClockMs) {
                        self.pendingSeekMs = nil
                        self.preSeekClockMs = nil
                        self.seekHoldTotalPolls = 0
                    } else {
                        // A seek still filling after ~1s (2 polls) may be a real network wait, and
                        // that surfaces as buffering AT THE TARGET (where the bar is pinned), so a
                        // slow-share seek shows an honest spinner instead of silence. The 2-poll
                        // floor + the VM's ~400ms debounce keep a healthy in-buffer seek silent;
                        // without the floor, every LAN seek would flash the spinner for a tick.
                        //
                        // The poll count ALONE can't tell the two cases apart, because failing
                        // the settle test above is not evidence of a stall: `clockMs` keeps
                        // reporting the PRE-seek position until libvlc's input republishes time
                        // after demuxing at the new offset, which on wmv/SMB overruns the ±3s
                        // tolerance for the whole 10-poll budget. That rode a scrim over healthy
                        // A/V, then jumped. So gate on the same honest signal the stall detector
                        // trusts: demux bytes still climbing = the fetch is fine and only the
                        // clock is behind; bytes flat across the hold = actually starving
                        // (raise the scrim, exactly as before).
                        //
                        // A healthy hold still can't stay SILENT, though: with nothing published
                        // the bar sits pinned at the target the `seek()` beat wrote until the
                        // clock republishes (~2s on wmv) and then jumps forward. So extrapolate
                        // instead: the audio and video are already running at the new offset, so
                        // target + elapsed × rate is the honest position, and the settle below
                        // publishes the real clock and corrects it (≈0 on an accurate landing).
                        switch Self.seekHoldAction(polls: self.pendingSeekPolls,
                                                   readBytes: readBytes,
                                                   previousReadBytes: self.seekHoldReadBytes) {
                        case .hold:
                            // Nothing worth a beat yet, but the client renderer still needs a
                            // position: the picture is pinned at the target.
                            self.publish(positionMs: target)
                        case .buffer:
                            // Nothing is being consumed at all — the starvation scrim, pinned at
                            // the target (where the bar is) rather than at the clock the seek
                            // moved away from. The 45s bound belongs to the stall detector above,
                            // which sees this tick like any other.
                            self.emitBuffering(positionMs: target)
                        case .extrapolate:
                            // Same accessor `pause()` publishes from, so the hold's value and the
                            // pause beat can never drift apart. The guards above already cleared
                            // the resume/flush holds, so this resolves to this seek's extrapolation.
                            self.emitPosition(isPlaying: true, positionMs: self.heldPositionMs)
                        }
                        self.seekHoldReadBytes = readBytes
                        continue
                    }
                }
                // The honest-stall SCRIM (the arming itself is above, ahead of the holds). By
                // here the player CLAIMS to be playing (isPlaying) with NO seek/flush/resume
                // settling, so a frozen pair really is a dead stream rather than a guarded
                // window: `isPlaying` reflects intent, not frames (VLCKit#578), so without this
                // the poll emits `.playing` over it forever. Bytes advancing = network alive
                // (buffer refilling) and time advancing = playing, both → not stalled; only BOTH
                // frozen for 6 polls (3s) trips. See `StallDetector`.
                if stalled {
                    self.emitBuffering(positionMs: nowMs)   // honest scrim; keep polling for recovery
                    continue
                }
                if self.isStalled {
                    // The clock (or demux) advanced again — the stall cleared; drop back to live beats.
                    self.isStalled = false
                    self.stallWatchdog.disarm()
                }
                self.emitPosition(isPlaying: true, positionMs: nowMs)
            }
        }
    }

    /// The duration (ms) to publish: the container's real length once libvlc resolves it, else the
    /// read-rate runtime estimate for incomplete media (captured once and held), else 0 (→
    /// `.indefinite`). See `estimateDurationMs` / `lastEstimateMs`.
    private func effectiveDurationMs() -> Int32 {
        guard let media = currentMedia else { return 0 }
        // `media.length` is nullTime until libvlc resolves it, and nullTime's `intValue`
        // is 0 on 3.x — which the `> 0` test below already rejects, so reading through
        // `validClockMs` here is about honesty, not a different outcome.
        let real = Self.validClockMs(media.length) ?? 0
        if real > 0 { return real }
        // No container length (incomplete/truncated media). Capture the read-rate estimate ONCE,
        // while observed (no pending seek/resume/flush — a seek re-reads bytes and skews the demux
        // counter), then hold it. `fileSizeBytes` (from the SMB lister) is the only way to a total
        // once `position` is out. Skipped when a resume offset was applied (`estimateAnchoredAtZero`
        // == false): the estimate assumes playback ran from 0, so a resume would divide
        // fileSize × (resumeOffset + played) by the demux bytes read only SINCE the seek and yield a
        // garbage total. `demuxReadBytes` is widened UNSIGNED — libvlc's counter is a C int that
        // wraps negative past ~2 GB, which the `> 0` guard would otherwise reject. (VBR note:
        // capturing once ~3s in can over/under-read a file with an atypical-bitrate opening; the
        // runtime is approximate by design.)
        if lastEstimateMs == 0, estimateAnchoredAtZero, let size = fileSizeBytes,
           pendingSeekMs == nil, pendingStartMs == nil, rateFlushAnchorMs == nil,
           let est = Self.estimateDurationMs(
               fileSizeBytes: size,
               playedMs: clockMs,
               demuxReadBytes: demuxReadBytes
           ) {
            lastEstimateMs = est
        }
        return lastEstimateMs
    }

    /// Publish a single position beat. The ONLY thing gated is `clockMs`'s synthesized -1
    /// (3.x's `player.time` never reads -1 — `VLCTime.value` is nil when libvlc has no clock,
    /// and `clockMs` turns that into the sentinel) — emitting that would snap the
    /// scrubber and `lastPosition` to 0:00 and risk a 0:00 progress/stop report that loses the
    /// resume point (`liveBeat` does that guard, on POSITION). An unresolved length is NOT a
    /// reason to skip: `media.length` stays 0 forever on incomplete media (truncated tail → no
    /// moov atom), and gating the beat on it wedged the player in `.loading` even while frames
    /// rendered. Readiness is "frames are rendering" (a valid position), not "duration is known"
    /// — the beat ships with an `.indefinite` duration when length is unknown. VLC's analogue of
    /// AVKit's `.playing`-off-`timeControlStatus` (which is likewise not duration-gated). Shared
    /// by pause(), seek(), and the progress poll. Playing-vs-paused comes from the caller (the
    /// poll/seek read `player.isPlaying`; pause forces false), never from `player.state` (stuck
    /// on `.buffering`).
    private func emitPosition(isPlaying: Bool, positionMs: Int32) {
        let beat = currentMedia == nil ? nil : Self.liveBeat(
            isPlaying: isPlaying, positionMs: positionMs, durationMs: effectiveDurationMs(),
            provenance: provenanceNow
        )
        if beat != nil {
            loadWatchdog.disarm()   // a real position beat = frames are rendering, the load is alive
        }
        publish(positionMs: positionMs, beat)
    }

    /// Publish a buffering beat (same position-guarding as `emitPosition`). Used by the rate-change
    /// flush bridge so a re-decode hold reads as buffering (the app debounces it) rather than a
    /// frozen position.
    private func emitBuffering(positionMs: Int32) {
        let beat: PlaybackState? = currentMedia != nil && positionMs >= 0
            ? .buffering(
                position: Self.vlcTimeToCMTime(ms: positionMs),
                duration: Self.vlcDurationToCMTime(ms: effectiveDurationMs()),
                buffered: nil,
                provenance: provenanceNow
            )
            : nil
        publish(positionMs: positionMs, beat)
    }

    /// Emit `.ready` with the current duration + track inventory. Driven from the poll's
    /// inventory diff (`publishInventoryIfChanged`) — 3.x has no length or track delegate.
    /// Not gated on a known length: the app's `.ready` handler only adopts the track inventory
    /// (duration rides the position beats), so publishing tracks while the length is still
    /// unknown is correct — the duration carried here is `.indefinite` until it resolves.
    private func emitReady(_ inventory: TrackInventory) {
        guard currentMedia != nil else { return }
        loadWatchdog.disarm()   // tracks/length resolved = the demux is progressing, the load is alive
        continuation.yield(.ready(
            duration: Self.vlcDurationToCMTime(ms: effectiveDurationMs()),
            tracks: inventory
        ))
    }

    private func buildTrackInventory() -> TrackInventory {
        let audio = audioDescriptors()
        let subtitles = subtitleDescriptors()
        // 3.x's track arrays carry no language, so it is recovered from the parsed
        // container's `tracksInformation` (keyed by the same libvlc track id). Nil when
        // the media hasn't been parsed or the stream is untagged — the app's
        // language-preference matching simply finds nothing then.
        let tracksInformation = currentMedia?.tracksInformation ?? []
        let languages = Self.trackLanguages(from: tracksInformation)
        // Same join, second fact: the codec fourcc tells us which tracks this libvlc
        // binary has no decoder for, so the menu can show them as unavailable instead
        // of offering a pick that plays silence.
        let undecodable = Self.undecodableTrackIDs(from: tracksInformation)
        let audioTracks = audio.map {
            Self.buildAudioTrack(
                id: String($0.id),
                name: $0.name,
                language: languages[$0.id],
                isUnsupported: undecodable.contains($0.id)
            )
        }
        let subtitleTracks = subtitles.map {
            Self.buildSubtitleTrack(id: String($0.id), name: $0.name, language: languages[$0.id])
        }
        // Surface VLC's own default selection so the menus check the active track
        // at start (AVKit's inventory already does this; without it the VLC path
        // opened with every track unchecked). A subtitle is often unselected → nil.
        let selectedAudioID = audio.first(where: { $0.id == player.currentAudioTrackIndex })
            .map { TrackID.vlc(String($0.id)) }
        let selectedSubtitleID = subtitles.first(where: { $0.id == player.currentVideoSubTitleIndex })
            .map { TrackID.vlc(String($0.id)) }
        return TrackInventory(
            audio: audioTracks,
            subtitles: subtitleTracks,
            selectedAudioID: selectedAudioID,
            selectedSubtitleID: selectedSubtitleID
        )
    }

    /// The audio elementary streams VLC currently offers, "Disabled" pseudo-track removed.
    private func audioDescriptors() -> [VLCTrackDescriptor] {
        Self.trackDescriptors(indexes: player.audioTrackIndexes, names: player.audioTrackNames)
    }

    /// The text elementary streams VLC currently offers, "Disabled" pseudo-track removed.
    private func subtitleDescriptors() -> [VLCTrackDescriptor] {
        Self.trackDescriptors(indexes: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames)
    }

    /// Re-emit `.ready` when the inventory the app would see has actually changed. Cheap
    /// enough to run every 500ms tick (small array reads + one `tracksInformation` walk),
    /// and the diff is what keeps it from re-publishing an identical inventory forever.
    /// With no length/track delegates on 3.x this diff is the only change signal. Diffs
    /// the FULL built inventory (see `lastPublishedInventory`) and hands the build to
    /// `emitReady` so a re-emit doesn't pay for it twice.
    private func publishInventoryIfChanged() {
        guard let media = currentMedia else { return }
        let inventory = buildTrackInventory()
        let lengthResolved = (Self.validClockMs(media.length) ?? 0) > 0
        guard inventory != lastPublishedInventory
                || lengthResolved != lastPublishedLengthResolved else { return }
        lastPublishedInventory = inventory
        lastPublishedLengthResolved = lengthResolved
        emitReady(inventory)
    }

    /// Idempotent one-time setter for VLC's events configuration. The first access
    /// runs the closure exactly once (Swift `static let` semantics); later accesses
    /// are no-ops. Every player this engine builds goes through `makePlayer`, which
    /// touches this first, so the legacy events config (main-queue delegate delivery)
    /// is installed before any `VLCMediaPlayer` exists — which the `assumeIsolated`
    /// delegate hops require.
    private static let _eventsConfigured: Void = {
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()
        #if DEBUG
        // Mirror libvlc's audio/clock log lines into the unified log so an audio dropout
        // can be traced to starvation vs a decoder failure.
        VLCLibrary.shared().loggers = [VLCAudioDiagnosticsLogger()]
        #endif
    }()

    /// Ensures VLC delivers delegate callbacks on the main queue. Idempotent and
    /// safe to call multiple times; `init()` invokes it automatically, so an
    /// explicit app-launch call is optional belt-and-suspenders.
    public static func configureVLCEvents() {
        _ = _eventsConfigured
    }

    // MARK: - Pure static helpers (testable without a live VLC decode)

    /// The index 3.x uses for "no track selected" on `currentAudioTrackIndex` /
    /// `currentVideoSubTitleIndex`, and the id of the "Disabled" pseudo-track VLC prepends
    /// to every `*TrackIndexes` array.
    nonisolated static let disabledTrackIndex: Int32 = -1

    /// One selectable elementary stream as 3.x vends it: the libvlc track id (the value
    /// `currentAudioTrackIndex` / `currentVideoSubTitleIndex` take) plus its display name
    /// off the parallel index/name arrays — the whole track API 3.x exposes.
    struct VLCTrackDescriptor: Equatable, Sendable {
        let id: Int32
        let name: String
    }

    /// Zip 3.x's parallel `*TrackIndexes` / `*TrackNames` arrays into descriptors, dropping
    /// the "Disabled" pseudo-track VLC prepends (id -1). Untyped `NSArray`s come back as
    /// `[Any]`, so both element casts are defensive: a slot that isn't the documented
    /// `NSNumber`/`NSString` pair is skipped rather than crashing the inventory. Pure so the
    /// filtering can be tested without a live decode.
    nonisolated static func trackDescriptors(indexes: [Any], names: [Any]) -> [VLCTrackDescriptor] {
        zip(indexes, names).compactMap { rawID, rawName in
            guard let id = (rawID as? NSNumber)?.int32Value, id != disabledTrackIndex,
                  let name = rawName as? String
            else { return nil }
            return VLCTrackDescriptor(id: id, name: name)
        }
    }

    /// libvlc track id → language tag, read off the parsed container's `tracksInformation`.
    /// 3.x's player-side track arrays carry only a display name, so this is the only place a
    /// language can come from; `VLCMediaTracksInformationId` is the same id the player's
    /// index arrays vend, which is what makes the join valid. Empty for unparsed media.
    /// Pure so the parsing can be tested without a live decode.
    nonisolated static func trackLanguages(from tracksInformation: [Any]) -> [Int32: String] {
        var languages: [Int32: String] = [:]
        for case let info as [String: Any] in tracksInformation {
            guard let id = (info[VLCMediaTracksInformationId] as? NSNumber)?.int32Value,
                  let language = info[VLCMediaTracksInformationLanguage] as? String,
                  !language.isEmpty
            else { continue }
            languages[id] = language
        }
        return languages
    }

    /// Codec fourccs no shippable libvlc build can decode.
    ///
    /// Dolby TrueHD (`trhd`) and its MLP predecessor (`mlp `) are left out of the
    /// build-config allowlist VideoLAN compiles its binaries with, so the decoder simply
    /// isn't in the library — proven in the lab on MobileVLCKit 3.7.3 ("Codec `trhd'
    /// (TrueHD Audio) is not supported"). Such files
    /// usually carry a coexisting AC3 "Compatibility Track", which VLC falls back to on
    /// its own, so default playback still has sound — only an explicit pick of the
    /// TrueHD track goes silent, which is what the marking prevents.
    nonisolated static let undecodableAudioFourccs: Set<String> = ["trhd", "mlp "]

    /// The libvlc track ids whose codec is in `undecodableAudioFourccs`, read off the same
    /// `tracksInformation` array the language join uses. Empty for unparsed media — the
    /// honest default, since "we don't know the codec" must never disable a track.
    /// Pure so the parsing can be tested without a live decode.
    nonisolated static func undecodableTrackIDs(from tracksInformation: [Any]) -> Set<Int32> {
        var ids: Set<Int32> = []
        for case let info as [String: Any] in tracksInformation {
            guard let id = (info[VLCMediaTracksInformationId] as? NSNumber)?.int32Value,
                  let codec = (info[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value,
                  undecodableAudioFourccs.contains(fourccString(from: codec))
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Decodes libvlc's packed codec fourcc into its four characters.
    ///
    /// `VLC_FOURCC(a,b,c,d)` puts `a` in the LOW byte, so the characters read out
    /// least-significant-byte first: 0x64687274 is "trhd", 0x34363268 is "h264". A value
    /// carrying a non-printable byte isn't a fourcc at all and yields an empty string,
    /// which matches nothing.
    nonisolated static func fourccString(from value: UInt32) -> String {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The `Int32` libvlc track id behind a `TrackID`, or nil if the id isn't in the VLC
    /// namespace (an AVKit option index or a Jellyfin stream index) or isn't a number.
    nonisolated static func trackIndex(from id: TrackID) -> Int32? {
        id.vlcTrackID.flatMap(Int32.init)
    }

    /// A `VLCTime`'s milliseconds, or nil when libvlc has no value for it.
    ///
    /// `VLCTime.nullTime.intValue` is **0** on 3.x, so `intValue` alone cannot tell "no
    /// clock / unresolved length" from a genuine 0:00 — only the nullable `value` can.
    /// Widened through `int64Value` and clamped so an out-of-range NSNumber saturates
    /// instead of trapping.
    ///
    /// **A genuine 0 ms is indistinguishable from "no clock" and 3.x offers no way out.**
    /// `-[VLCTime initWithInt:]` drops a zero, so `value` is nil for both. The cost is
    /// cosmetic and bounded to the instant of a rewind-to-start: `clockMs` reports -1, the
    /// beat is suppressed and the client overlay hides its cue until the next tick moves the
    /// clock off 0. Synthesizing a 0 instead would trade that for the far worse failure —
    /// every pre-first-frame poll snapping the scrubber and the persisted resume point to
    /// 0:00 — so the ambiguity stays, deliberately.
    nonisolated static func validClockMs(_ time: VLCTime) -> Int32? {
        time.value.map { Int32(clamping: $0.int64Value) }
    }

    /// Clamp a resume `CMTime` to a positive VLC millisecond offset, or nil if there's
    /// nothing to resume to (no time, non-finite, or ≤ 0). The reject-if-≤0 policy is the only
    /// difference from `clampSeekMs`; the floor/overflow clamp itself is shared.
    static func startMs(from time: CMTime?) -> Int32? {
        guard let time else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return clampSeekMs(seconds: seconds)
    }

    /// Clamp a millisecond offset (from an already-finite seconds value) into `0...Int32.max` — the
    /// shared floor/overflow clamp for both `startMs` and user seeks. A seek to 0:00 is valid
    /// (rewind to start), so this FLOORS negatives to 0 rather than rejecting them — keeping seek in
    /// agreement with the `positionMs >= 0` emit guard (`liveBeat`): a rewind-before-zero lands at
    /// 0:00 instead of a negative target the poll could never converge on.
    nonisolated static func clampSeekMs(seconds: Double) -> Int32 {
        Int32(min(max(seconds * 1000, 0), Double(Int32.max)))
    }

    /// Playback (ms) that must elapse before the read-rate estimate is trusted — long enough for
    /// the bounded read-ahead cache (network-caching, ~3s) to amortize so `readBytes / playedTime`
    /// approximates the content byte-rate rather than the cache-fill spike.
    nonisolated static let estimateFloorMs: Int32 = 3_000

    /// Estimate the total runtime (ms) of media whose container length never resolves — a
    /// truncated/incomplete file (no trailing `moov` atom). libvlc's `position` is `time / length`,
    /// so it's ~0 when length is 0 and useless here. The length-INDEPENDENT signal is the DEMUX
    /// byte counter (`statistics.demuxReadBytes`) — NOT the input `readBytes`: a device trace showed
    /// `readBytes` racing 100× ahead of the demuxer (16.9 MB read vs 154 KB demuxed in 3 s) because
    /// it counts the network read-ahead cache, which yielded a nonsense 56 s total. `demuxReadBytes`
    /// tracks what's actually been consumed into frames, so demux-rate = `demuxReadBytes / playedTime`
    /// ≈ the content byte-rate, and the whole file's runtime = `fileSize / demux-rate = fileSize ×
    /// playedMs / demuxReadBytes`. `fileSize` comes from the SMB lister (the engine can't derive
    /// total bytes any other way once `position` is out). Accurate for CBR; VBR is within the intro's
    /// bitrate skew, which the user accepts. Nil until the floor, and for any degenerate input
    /// (missing size/bytes, or an estimate below what already played) so a bad signal falls back to
    /// the indeterminate bar rather than a nonsense total. Pure: testable without a live decode.
    nonisolated static func estimateDurationMs(fileSizeBytes: Int64, playedMs: Int32, demuxReadBytes: Int) -> Int32? {
        guard fileSizeBytes > 0, demuxReadBytes > 0, playedMs >= estimateFloorMs else { return nil }
        let est = Double(fileSizeBytes) * Double(playedMs) / Double(demuxReadBytes)
        guard est.isFinite, est >= Double(playedMs), est <= Double(Int32.max) else { return nil }
        return Int32(est)
    }

    nonisolated static func vlcTimeToCMTime(ms: Int32) -> CMTime {
        guard ms > 0 else { return .zero }
        return CMTime(value: CMTimeValue(ms), timescale: 1000)
    }

    /// A *duration* from libvlc, where a non-positive value means "not resolvable from the
    /// bytes we have" — NOT 0:00. libvlc leaves `media.length` at 0 (or the -1 sentinel)
    /// when the container's total length isn't downloaded yet: a truncated/incomplete file
    /// whose trailing index (MP4 `moov` atom, MKV `Cues`) is in the missing tail. That is an
    /// *indeterminate* duration, so map it to AVFoundation's own sentinel `.indefinite` —
    /// the same value AVKit passes through for an unknown-length item — rather than `.zero`.
    /// Downstream the app reads one `hasKnownDuration` truth (`CMTime.isNumeric`) off this, so
    /// the player becomes interactive with a non-seekable bar instead of wedging in `.loading`.
    /// Distinct from `vlcTimeToCMTime`, which is for POSITION (where 0 legitimately means 0:00).
    nonisolated static func vlcDurationToCMTime(ms: Int32) -> CMTime {
        guard ms > 0 else { return .indefinite }
        return CMTime(value: CMTimeValue(ms), timescale: 1000)
    }

    /// The live position beat to publish for a poll/seek/pause sample, or nil to SKIP it.
    /// Skips only when the position is `clockMs`'s synthesized pre-first-frame sentinel (-1;
    /// 3.x reports "no clock" as a nil `VLCTime.value`, never as -1) — emitting that would
    /// snap `lastPosition` to 0:00 and risk
    /// losing the resume point. An UNKNOWN length (`durationMs` <= 0) does NOT skip: readiness
    /// is "frames are rendering" (a valid position), not "duration is known", so the beat ships
    /// with an `.indefinite` duration and the player leaves `.loading` even on incomplete media
    /// whose length never resolves. Pure so the gate is testable without a live decode.
    nonisolated static func liveBeat(
        isPlaying: Bool, positionMs: Int32, durationMs: Int32, provenance: PositionProvenance
    ) -> PlaybackState? {
        guard positionMs >= 0 else { return nil }
        return positionState(isPlaying: isPlaying, positionMs: positionMs,
                             durationMs: durationMs, provenance: provenance)
    }

    /// Whether libvlc's clock has landed on the requested target — ±3s, which tolerates a
    /// keyframe-snapped landing. The ONLY positive evidence the engine has that the seek
    /// completed. Pure so the seek-overshoot guard can be tested without a live player.
    static func seekHasConverged(now: Int32, target: Int32) -> Bool {
        // Int arithmetic: `now` is a raw libvlc clock and `target` a clamped Int32 ms, so a
        // difference at the extremes overflows Int32 and `abs` traps on Int32.min.
        abs(Int(now) - Int(target)) <= 3_000
    }

    /// Whether the post-seek hold has spent its poll budget (10 polls ≈ 5s at the 500ms
    /// cadence). Expiry is a GIVE-UP, not a landing: it exists so a seek that never converges
    /// exactly (a clamped or keyframe-snapped target far off the request) still resumes live
    /// tracking instead of holding forever. Mirrors `seekHasConverged`.
    static func seekHoldExpired(polls: Int) -> Bool {
        polls >= 10
    }

    /// Whether the engine has given up on the seek outright: 30 polls ≈ 15s at the 500ms
    /// cadence, counted from the ORIGINAL seek (`seekHoldTotalPolls`).
    ///
    /// `seekHoldExpired`'s budget is CONDITIONAL — a clock that never left the pre-seek
    /// neighbourhood keeps holding past it, which is what stops an unmoved clock shipping as a
    /// landing. Two shapes make that condition permanent and the hold immortal:
    ///  • a BACKWARD seek whose clock free-runs FORWARD off the pre-seek position — every
    ///    reading is further from the target than from the origin, at every poll count;
    ///  • a source whose clock never republishes at all while the demux keeps climbing — the
    ///    `.extrapolate` arm forever, so the `.buffer` arm never fires and the stall detector
    ///    (which needs BOTH axes frozen) never trips either.
    /// Neither releases, so the bar rides an extrapolation until the media ends. This is the
    /// floor under both, and it is unconditional on purpose.
    ///
    /// Ordered against the app's own `SeekHold.watchdog` (20s) deliberately: the ENGINE has to
    /// be the one that gives up first, so the beat that ends the app's hold is an honest
    /// `.observed` clock rather than whatever the app's watchdog happened to fire on. 15s
    /// leaves 5s of margin at the 500ms cadence.
    static func seekHoldAbandoned(polls: Int) -> Bool {
        polls >= 30
    }

    /// Whether a post-seek poll should drop the hold and resume publishing the raw clock.
    ///
    /// Convergence releases it. The abandon cap releases it too, unconditionally — see
    /// `seekHoldAbandoned` for the two shapes that would otherwise hold forever; what ships
    /// then is the honest raw clock, labelled `.observed`, never a re-dressed pre-seek value
    /// (by then the clock either moved or the seek is unknowable, and freezing the bar on a
    /// guess for the rest of the session is the worse lie).
    ///
    /// Expiry releases as well — but only once the clock is NEARER the
    /// target than the position the seek started from, and that condition is the whole reason
    /// this is not just `converged || expired`. Releasing on a clock that never left the
    /// pre-seek neighbourhood republishes it as a landed `.playing`: the bar silently snaps
    /// back to where the user seeked FROM, and the resume point follows it. The extrapolation
    /// the hold publishes instead is a guess, but an honest one.
    ///
    /// "Nearer the target than the origin", not the weaker "moved at all" or even "moved
    /// toward the target": a libvlc clock that has not republished is not FROZEN, it free-runs
    /// from the pre-seek position while the input demuxes at the new offset. So on a forward
    /// seek every one of those readings has "moved", and has moved toward the target — 1 ms of
    /// creep or 5 s of interpolation would both release, which is exactly the snap-back. Past
    /// the midpoint is the cheapest test the interpolation cannot satisfy, and a real landing
    /// (a keyframe snap, a clamp near the request) satisfies it trivially.
    ///
    /// The bound it accepts: a seek clamped far SHORT of the request — asking for 08:00 of a
    /// 02:00 file — lands nearer the origin and holds until the abandon cap ends it. No scrub
    /// surface can request past the duration; only a skip button off the end can.
    ///
    /// A nil `preSeekClockMs` (no clock at seek time) has nothing to compare against, so
    /// expiry releases: an unknown is not evidence of staleness.
    static func seekHoldShouldRelease(
        now: Int32, target: Int32, polls: Int, totalPolls: Int, preSeekClockMs: Int32?
    ) -> Bool {
        if seekHasConverged(now: now, target: target) { return true }
        if seekHoldAbandoned(polls: totalPolls) { return true }
        guard seekHoldExpired(polls: polls) else { return false }
        guard let preSeekClockMs else { return true }
        return abs(Int(now) - Int(target)) < abs(Int(now) - Int(preSeekClockMs))
    }

    /// What a post-seek poll inside the hold should publish at the held target.
    enum SeekHoldAction: Equatable, Sendable {
        /// Publish nothing this tick: the fetch has stalled, but not for long enough to be
        /// worth a scrim (the 2-poll floor).
        case hold
        /// The scrim at the target: nothing is being consumed at all.
        case buffer
        /// A live `.playing` beat at the extrapolated position (see `seekHoldPositionMs`):
        /// the fetch is healthy and only libvlc's clock is behind.
        case extrapolate
    }

    /// Which of those a post-seek poll inside the hold is looking at. Two very different things
    /// fail `seekHasConverged`, and only one of them is a wait:
    ///  • the clock hasn't republished yet: libvlc still reports the pre-seek position
    ///    while the input demuxes at the new offset (seconds on wmv/SMB), even though the
    ///    fetch is healthy and frames are landing. Extrapolate.
    ///  • the fetch has actually stopped: nothing is being consumed at all. Scrim.
    /// The demux byte counter separates them (the same signal `StallDetector` trusts;
    /// libvlc's `position` is length-relative and useless on unresolved media). Any change
    /// counts as progress, so the counter's UInt32 wrap can't fake a stall. The 2-poll floor
    /// stays on the SCRIM only: it plus the VM's ~400ms debounce is what keeps a brief
    /// hiccup off the screen, while a healthy hold reports position from the first tick.
    /// Pure so the gate is testable without a live decode; mirrors `seekHasConverged`.
    static func seekHoldAction(polls: Int, readBytes: Int, previousReadBytes: Int) -> SeekHoldAction {
        guard readBytes == previousReadBytes else { return .extrapolate }
        return polls >= 2 ? .buffer : .hold
    }

    /// The position (ms) to publish during a healthy seek hold: the seek target plus the
    /// wall time the poll has spent holding, scaled by the playback rate. The poll cadence
    /// is the clock (`polls × pollMs` is deterministic and needs no `Date` read), and the
    /// rate matters because a 2× session covers 1000ms of media per 500ms tick.
    ///
    /// Clamped to the media duration so a seek near the tail can't extrapolate past the end
    /// and drive the bar to >100%; an unresolved duration (`durationMs <= 0`, incomplete
    /// media) has no ceiling to clamp to and rides the raw extrapolation. Never below the
    /// target: this only ever moves the bar forward, and the settle correction is what walks
    /// it back if libvlc landed short. Pure so the value is testable without a live decode.
    static func seekHoldPositionMs(
        targetMs: Int32, polls: Int, pollMs: Int, rate: Float, durationMs: Int32
    ) -> Int32 {
        let elapsedMs = Double(polls * pollMs) * Double(max(0, rate))
        let ceiling = durationMs > 0 ? Double(durationMs) : Double(Int32.max)
        let extrapolated = min(Double(targetMs) + elapsedMs, ceiling)
        return Int32(min(max(extrapolated, Double(targetMs)), Double(Int32.max)))
    }

    /// The value behind the `heldPositionMs` property, hoisted out so the precedence between
    /// the three holds is testable without a live decode. Order matters: the resume offset
    /// outranks everything (it hasn't been applied to the clock yet), a rate-flush anchor
    /// outranks a seek (a flush and a user seek never coexist, but the flush is the one the
    /// poll is publishing when both are somehow set), and a settling seek reports the same
    /// extrapolation the poll's hold publishes. With nothing held the raw clock IS the truth,
    /// including its pre-first-frame -1 sentinel, which `liveBeat` then suppresses.
    static func heldPositionMs(
        pendingStartMs: Int32?, rateFlushAnchorMs: Int32?, pendingSeekMs: Int32?,
        pendingSeekPolls: Int, pollMs: Int, rate: Float, durationMs: Int32, clockMs: Int32
    ) -> Int32 {
        if let start = pendingStartMs { return start }
        if let anchor = rateFlushAnchorMs { return anchor }
        guard let target = pendingSeekMs else { return clockMs }
        return seekHoldPositionMs(
            targetMs: target, polls: pendingSeekPolls, pollMs: pollMs,
            rate: rate, durationMs: durationMs
        )
    }

    /// Whether the progress poll should push `desired` onto the live player. libvlc applies
    /// `rate` to the active input, so a rate chosen before the input existed (the re-apply
    /// right after `play()`) never took and must be re-asserted once playing. The epsilon
    /// stops a redundant write on every 500ms tick when the live rate already matches. Pure
    /// so the gate is testable without a live decode (the `player.rate` write itself needs a
    /// real input, like the rest of this engine).
    static func shouldReassertRate(current: Float, desired: Float) -> Bool {
        abs(current - desired) > 0.001
    }

    /// Whether the poll should re-push a dropped play command: the user wants playback
    /// (`desiredPlaying`), the input reports paused (`!isPlaying`), and the input is in a
    /// live state where a resume is meaningful. `.opening` is excluded (initial play() is
    /// still taking effect — reasserting there would just race the open), and the
    /// stopped/ended/error terminals are excluded so a finished or failed input can never
    /// be restarted into a ghost session. `.esAdded` is excluded too: 3.x caches it as the
    /// player state, and it lands *during* the open (each elementary stream announces
    /// itself), so it belongs with `.opening` rather than with the live states. Pure so the
    /// gate is testable without a live decode; mirrors `shouldReassertRate`.
    nonisolated static func shouldReassertPlay(desiredPlaying: Bool, isPlaying: Bool, state: VLCMediaPlayerState) -> Bool {
        guard desiredPlaying, !isPlaying else { return false }
        switch state {
        case .buffering, .playing, .paused:
            return true
        default:
            return false
        }
    }

    /// Whether a transport command (`play()`, `pause()`) may reach the input at all. False
    /// exactly while the exit latch stands (`endAudio()` → `audioEnded`): that path stopped
    /// the player to cut queued audio, so a late play would unmute and restart it behind a
    /// dismissing UI, and a late pause would command the same non-Sendable player the
    /// detached `player.stop()` is still winding down on its own thread. One-way: only
    /// `load()` clears the latch. Pure so the gate is testable without a live decode;
    /// mirrors `shouldReassertPlay`.
    nonisolated static func shouldHonorTransport(audioEnded: Bool) -> Bool { !audioEnded }

    /// Whether the poll's LIVE pass (rate reassert → resume hold → seek settle → stall
    /// detection → `.playing` beat) should run this tick. `player.isPlaying` alone is not
    /// enough: after `pause()` it can keep reading true for seconds on a wedged SMB read, and
    /// the live pass would then climb `pendingSeekPolls` and publish extrapolated `.playing`
    /// beats against an intended pause, walking `currentPosition` and the persisted resume
    /// point forward under a paused picture. The poll's contract is to stay silent while
    /// paused, so the intent has to agree. Closes the inverse of `shouldReassertPlay`, which
    /// handles `desiredPlaying && !isPlaying`. Pure so the gate is testable without a live decode.
    nonisolated static func shouldRunLiveTick(desiredPlaying: Bool, isPlaying: Bool) -> Bool {
        desiredPlaying && isPlaying
    }

    /// Whether the rate-change flush bridge should stop holding and resume live position tracking:
    /// VLC's clock has advanced past the flush anchor (the re-decode produced output at the new
    /// rate), or the poll budget elapsed (resume even if it never cleanly advances, so the counter
    /// can't hold forever). The +200ms margin tolerates clock jitter at the hold point; 8 ticks ≈
    /// 4s at the 500ms poll. Pure so the gate is testable without a live decode. Mirrors `seekHasConverged`.
    static func flushBridgeShouldResume(now: Int32, anchor: Int32, ticks: Int) -> Bool {
        now > anchor + 200 || ticks >= 8
    }

    nonisolated static func positionState(
        isPlaying: Bool, positionMs: Int32, durationMs: Int32, provenance: PositionProvenance
    ) -> PlaybackState {
        let position = vlcTimeToCMTime(ms: positionMs)
        let duration = vlcDurationToCMTime(ms: durationMs)
        // buffered: nil — libvlc exposes no loaded-range query; its small network
        // cache wouldn't meaningfully feed the bar's instant-seek layer anyway.
        return isPlaying
            ? .playing(position: position, duration: duration, buffered: nil, provenance: provenance)
            : .paused(position: position, duration: duration, buffered: nil, provenance: provenance)
    }

    /// `id` is VLC's own `trackId` string; it is tagged `.vlc` so it can never be
    /// confused with an AVKit option index or a Jellyfin stream index.
    public static func buildAudioTrack(
        id: String, name: String, language: String?, isUnsupported: Bool = false
    ) -> AudioTrack {
        AudioTrack(id: .vlc(id), displayName: name, languageCode: language,
                   isUnsupported: isUnsupported)
    }

    public static func buildSubtitleTrack(id: String, name: String, language: String?) -> SubtitleTrack {
        SubtitleTrack(id: .vlc(id), displayName: name, languageCode: language, isForced: false)
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCKitEngine: VLCMediaPlayerDelegate {

    // MARK: — State changes

    /// 3.x delivers state as a `Notification`. The notification carries no state in its
    /// payload — the current value is read off `player.state`, which VLCKit caches from
    /// the same event before notifying. The legacy events config routes this callback to
    /// the main queue; Swift cannot prove that, so isolation is asserted via
    /// `assumeIsolated`.
    public nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            handleStateChanged(player.state)
        }
    }

    /// Snapshot taken: `saveVideoSnapshot(at:withWidth:andHeight:)` finished writing SOME PNG.
    /// The notification carries no path or capture identity, so it can't tell a genuine write for
    /// the in-flight `captureFrame()` apart from a stale notification belonging to an earlier,
    /// already-timed-out capture whose write raced back in after the fact — verifying the expected
    /// file actually landed on disk is what makes that distinction.
    ///
    /// A notification whose expected file is NOT there is therefore IGNORED, not failed. Failing it
    /// would resolve the continuation the current capture is waiting on and cancel its timeout, so
    /// one late write from the previous capture killed the next one before libvlc had even started
    /// it — a capture that would have succeeded reports nil instead. The in-flight capture keeps
    /// waiting; its own notification or its own 5s timeout ends it.
    ///
    /// Isolation shape matches the other delegate methods — legacy events config delivers on main;
    /// Swift can't prove it, so assert via `assumeIsolated`.
    public nonisolated func mediaPlayerSnapshot(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            guard snapshotFileReady() else { return }
            completeSnapshot(success: true)
        }
    }

    /// Whether the file this specific `captureFrame()` call is waiting on actually exists on
    /// disk. `snapshots`/`lastSnapshot` (the other VLCKit surfaces for "what did I just write")
    /// give back an undocumented name/UIImage, not a path to compare — checking the known
    /// expected path directly is the reliable signal.
    private func snapshotFileReady() -> Bool {
        guard let expected = snapshotExpectedPath else { return false }
        return FileManager.default.fileExists(atPath: expected)
    }

    // MARK: — Private (MainActor, called via assumeIsolated)

    private func handleStateChanged(_ state: VLCMediaPlayerState) {
        switch state {
        case .opening:
            continuation.yield(.loading)
        case .ended:
            // Natural end-of-stream. During teardown the delegate is nilled BEFORE
            // player.stop(), so this branch is never reached from teardown — no
            // spurious .ended beat.
            desiredPlaying = false   // finished input: the play-intent reassert must never restart it
            loadWatchdog.disarm()
            if currentMedia != nil {
                continuation.yield(.ended)
            }
        case .stopped:
            // NOT end-of-stream on 3.x — `.ended` is ("Stream has ended"); `.stopped` is
            // the stop / set-media transition and the initial idle state ("Player has
            // stopped"). A reused engine's `load()` assigns `player.media` on a live
            // player, which stops the old input and lands here mid track-switch;
            // surfacing that as `.ended` would fire a spurious end-of-playback (dismiss /
            // 100% progress) in the middle of the reload. Teardown nils the delegate
            // before stop(), so nothing legitimate ever needs an emit from this state.
            break
        case .error:
            desiredPlaying = false
            loadWatchdog.disarm()   // libvlc surfaced the failure itself; don't also time out
            continuation.yield(.failed(.assetNotPlayable))
        case .buffering, .playing, .paused, .esAdded:
            // Deliberately ignored for BEATS. VLC drops into `.buffering` freely during
            // normal playback and its `.playing`/`.paused` transitions are not reliable
            // (VideoLAN VLCKit#578/#128/#80). Progress and play/pause state come from
            // `startProgressPolling()` reading `player.isPlaying`, not from these
            // transitions. `.esAdded` is purely informational (an elementary stream
            // announced itself); the poll's inventory diff is what turns that into a
            // `.ready` re-emit.
            // BUT they're the "input opened, data is flowing" signal, so they disarm the load
            // watchdog — the deadline only guards "stuck opening a dead mount". Without this, a
            // remote pause landing before the first frame (pause() emits nothing: there is no
            // clock yet) or a slow first frame would let the deadline fire on healthy media.
            loadWatchdog.disarm()
        @unknown default:
            break
        }
    }
}

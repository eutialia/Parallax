import Foundation
import CoreMedia
import ParallaxCore
import VLCKitSPM

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
/// `player.media` is deliberately NOT nil'd — see `teardown()` (nil'ing it aborts in
/// `libvlc_media_retain` when PiP polls the media off-thread).
@MainActor
public final class VLCKitEngine: NSObject, PlaybackEngine, VLCPlayerHosting {

    // MARK: - Protocol requirements

    public nonisolated let id: PlaybackEngineID = .vlcKit

    public nonisolated let capabilities = PlaybackEngineCapabilities(
        supportsPiP: true,
        supportsVideoAirPlay: false,
        supportsAudioAirPlay: true,
        supportsNowPlayingIntegration: true
    )

    public nonisolated let state: AsyncStream<PlaybackState>
    private nonisolated let continuation: AsyncStream<PlaybackState>.Continuation

    // MARK: - VLC internals

    // `nonisolated(unsafe)` is required because Swift 6 forbids `nonisolated let`
    // for non-Sendable types, even though `let` is immutable. The player is only
    // ever mutated (delegate, media, play/stop) from MainActor-isolated code;
    // the nonisolated `vlcPlayer` accessor is read-only and accessed synchronously
    // from UIViewRepresentable contexts that cannot hop to MainActor.
    private nonisolated(unsafe) let player: VLCMediaPlayer

    /// The underlying `VLCMediaPlayer`, exposed `nonisolated` so the app's
    /// `UIViewRepresentable` make/update contexts can wire the video output without
    /// a `MainActor` hop.
    ///
    /// **Read/set `drawable` ONLY.** All other mutations (play/pause/stop, `media`,
    /// `time`) are owned by `VLCKitEngine` and run on the `@MainActor`; calling them
    /// on this returned reference from another isolation domain races the engine's
    /// control path. The cast site (`VLCPlayerHosting`) must treat this as a
    /// drawable handle, not a control surface.
    public nonisolated var vlcPlayer: VLCMediaPlayer { player }

    /// Live playback clock for the client-side subtitle overlay. Reads `player.time` (the
    /// same read-only, off-actor query the PiP media-controller already makes). Returns
    /// `.invalid` for the VLC_TICK_INVALID sentinel (`player.time` is -1 during
    /// buffering/seek) so the overlay skips rather than flashing the 0:00 cue.
    public nonisolated var currentTime: CMTime {
        let ms = player.time.intValue
        return ms >= 0 ? Self.vlcTimeToCMTime(ms: ms) : .invalid
    }

    // MARK: - Playback state tracking

    private var currentMedia: VLCMedia?

    /// Drives the progress beats. VLC 4.x sticks in `.buffering` during normal
    /// playback and almost never emits `.playing` (VideoLAN VLCKit#578/#128/#80),
    /// and its `mediaPlayerTimeChanged` delegate is throttled to the point of not
    /// firing here at all — so position never advanced off the delegate path. Mirror
    /// `AVKitEngine`'s periodic time observer: poll the live clock on a timer and
    /// publish beats ourselves. `player.isPlaying` is the reliable play/pause signal
    /// (it reads `true` while the bogus `.buffering` state lies), so beats derive
    /// playing-vs-paused from it, never from `player.state`.
    private var progressTask: Task<Void, Never>?

    /// VLC resolves the default track *selection* a beat or two after playback
    /// begins — after the first `.ready` already shipped with nothing selected (so
    /// the audio chip showed the generic "Audio" label, not the playing track). The
    /// poll re-emits the inventory once the selection appears; this guards that to a
    /// single re-emit per load.
    private var didEmitSettledInventory = false

    /// Resume offset (ms) to seek to once the demux is seekable, or nil. Resume is done
    /// by seeking — NOT the `:start-time` media option, which truncates the input so the
    /// scrubber can't span the full media or rewind before the resume point.
    private var pendingStartMs: Int32?

    /// Target (ms) of an in-flight user seek. Right after `setTime`, VLCKit's clock keeps
    /// interpolating from a now-stale reference and `player.time` briefly reads far past
    /// the target before the demux settles — surfacing as a scrubber overshoot that snaps
    /// back a poll later. The poll holds beats until the clock converges on this target
    /// (the `seek()` beat already carries the correct position); `pendingSeekPolls` is a
    /// fallback so a keyframe-snapped landing a few seconds off the request still resumes
    /// live tracking instead of freezing the bar.
    private var pendingSeekMs: Int32?
    private var pendingSeekPolls = 0

    /// Read-rate duration estimate (ms) for media whose container length never resolves — see
    /// `estimateDurationMs`. CAPTURED ONCE (the first settled sample past the floor) and HELD: the
    /// read-rate stays representative only before a seek re-reads bytes out of order, and a stable
    /// total is what the scrub bar needs. 0 until captured (→ `.indefinite`, indeterminate bar);
    /// reset on every fresh `load`. Never used once `media.length` resolves to a real value.
    private var lastEstimateMs: Int32 = 0

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

    /// The resume seek runs concurrently with playback (not awaited in `play()`), so it's
    /// stored here for `teardown()` to cancel — otherwise a dismiss during the readiness
    /// window would leave it polling and then write `player.time` on a stopped player.
    private var resumeTask: Task<Void, Never>?

    /// The app's standing "no engine subtitle" intent (Off, or it's drawing an external
    /// sidecar itself). VLC discovers embedded text tracks as the demux runs and
    /// auto-selects a default/forced one — which would render THROUGH the client overlay
    /// — so this latch lets `mediaPlayerTrackAdded` re-assert the deselect against a late
    /// track. Set by `setSubtitleTrack`; reset on each fresh `load`.
    private var subtitlesDisabled = false

    /// User-selected playback speed (1.0 = normal). libvlc applies `rate` to the *active
    /// input*, so a rate set before the demux is up is dropped — exactly when
    /// `PlayerViewModel.beginPlayback` re-applies the persisted speed (right after `play()`).
    /// Persist the intent here and have the progress poll re-assert it once playback is live,
    /// mirroring `AVKitEngine`'s `desiredRate`. A *live* mid-playback change is otherwise inaudible
    /// until the old-rate buffer drains (≈ network-caching) — `flushForImmediateRate` re-decodes in
    /// place to apply it promptly.
    private var desiredRate: Float = 1

    /// Position (ms) captured when a rate-change flush re-decode began, or nil. While set, the
    /// progress poll publishes buffering beats at this hold point until VLC's clock advances past
    /// it (re-decode done) — so the rate-change re-buffer reads as a brief buffering moment, not a
    /// silently frozen counter. See `flushForImmediateRate`.
    private var rateFlushAnchorMs: Int32?
    /// Poll ticks elapsed in the current flush bridge; a budget so a re-decode that never cleanly
    /// advances past the anchor still resumes live tracking instead of holding forever.
    private var rateFlushTicks = 0

    // MARK: - Init

    public override init() {
        _ = Self._eventsConfigured   // guarantee main-queue delegate delivery before the player exists
        // Bounded buffer — see the AVKitEngine init for the rationale. `.bufferingNewest`
        // keeps the freshest position plus any terminal beat; 32 ≈ 16s of 0.5s ticks, well
        // beyond what the MainActor consumer ever queues, so nothing real is ever dropped.
        let (stream, cont) = AsyncStream<PlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.state = stream
        self.continuation = cont
        self.player = VLCMediaPlayer()
        super.init()
        player.delegate = self
        // VLC quantizes `player.time` to its time-changed cadence, which DEFAULTS TO 1.0s
        // (`timeChangeUpdateInterval`, VLCMediaPlayer.h). So the polled position refreshes
        // only once a second and the scrubber counter steps a whole tick per refresh:
        // invisible at 1× (+1/s) but a +2/s skip-jump at 2× (every other second never shown).
        // Tighten it — plus `minimalTimePeriod` (the floor, default 0.5s, which would re-gate
        // a finer interval) — so `player.time` is fine-grained and the counter advances
        // smoothly at the playback rate. `timeChangeUpdateInterval` is only read at `play()`,
        // so set it here, before the first play. Cheap: we poll `player.time` rather than
        // consume the notification, so a finer cadence is just a fresher read (no flood).
        player.minimalTimePeriod = 100_000      // µs (0.1s) — below the interval so it can't gate it
        player.timeChangeUpdateInterval = 0.25  // s — 4×/s, finer than the 500ms poll
        continuation.yield(.idle)
    }

    // MARK: - PlaybackEngine

    public func load(_ asset: PlayableAsset) async throws {
        continuation.yield(.loading)
        didEmitSettledInventory = false
        subtitlesDisabled = false
        pendingStartMs = Self.startMs(from: asset.startTime)
        pendingSeekMs = nil
        rateFlushAnchorMs = nil   // a reused engine (track switch) must not bridge a stale flush
        lastEstimateMs = 0        // new media → re-estimate from scratch (a reused engine must not
                                  // carry the previous item's read-rate runtime estimate)
        fileSizeBytes = asset.hints.fileSizeBytes
        estimateAnchoredAtZero = pendingStartMs == nil   // a resume offset invalidates the read-rate estimate
        // VLCMedia(url:) returns optional; a nil result means the URL was rejected
        // by libvlc at construction time (e.g. empty path). Treat as unplayable.
        guard let media = VLCMedia(url: asset.url) else {
            continuation.yield(.failed(.assetNotPlayable))
            throw PlaybackError.assetNotPlayable
        }
        applyOptions(to: media, asset: asset)
        currentMedia = media
        player.media = media
        // External subtitles are NOT slaved to the player: VLC's text renderers can't shape
        // sidecar SRT/VTT on iOS, so they're fetched + drawn client-side (SubtitleOverlayView)
        // the same way the transcode path is — see PlayerViewModel.makeAsset.
    }

    public func play() async {
        player.play()
        // Start beats immediately so reportStart / cover-hide / the setRate re-apply aren't
        // gated on the resume readiness window. The resume seek runs concurrently (stored so
        // teardown() can cancel it); the poll holds beats until it lands, so there's no 0:00
        // flash. Mirrors AVKit's non-blocking play + detached seek-on-ready.
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

    public func pause() async {
        player.pause()
        // Emit the paused beat immediately rather than waiting for the next poll (which
        // stays silent while paused) so the transport button flips at once. `player.isPlaying`
        // can lag a frame after pause(), so force isPlaying: false.
        emitPosition(isPlaying: false, positionMs: player.time.intValue)
    }

    public func setRate(_ rate: Float) async {
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
        let pos = player.time.intValue
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

    public func seek(to time: CMTime) async {
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
        let ms = Self.clampSeekMs(seconds: seconds)
        player.time = VLCTime(int: ms)
        // Gate the poll until VLC's clock settles on this target so its transient
        // post-seek reads can't surface as an overshoot (see pendingSeekMs).
        pendingSeekMs = ms
        pendingSeekPolls = 0
        // Publish the new position now so the scrubber tracks the seek instead of
        // snapping back to the last polled position on release. Carry the pre-seek intent
        // so a playing seek stays `.playing` (no phantom paused glyph).
        emitPosition(isPlaying: wasPlaying, positionMs: ms)
    }

    public func setAudioTrack(_ track: AudioTrack) async {
        guard let vlcID = track.id.vlcTrackID else { return }
        for t in player.audioTracks where t.trackId == vlcID {
            t.isSelectedExclusively = true
            return
        }
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) async {
        guard let track else {
            subtitlesDisabled = true
            player.deselectAllTextTracks()
            return
        }
        guard let vlcID = track.id.vlcTrackID else { return }
        subtitlesDisabled = false
        for t in player.textTracks where t.trackId == vlcID {
            t.isSelectedExclusively = true
            return
        }
    }

    public func debugSnapshot() async -> PlaybackDebugInfo {
        var info = PlaybackDebugInfo()

        let size = player.videoSize
        if size.width > 0, size.height > 0 {
            info.presentationWidth = Int(size.width)
            info.presentationHeight = Int(size.height)
        }

        info.audibleOptions = player.audioTracks.map(\.trackName)
        info.selectedAudible = player.audioTracks.first(where: { $0.isSelected })?.trackName
        info.legibleOptions = player.textTracks.map(\.trackName)
        info.selectedLegible = player.textTracks.first(where: { $0.isSelected })?.trackName

        // VLC stores the subtitle delay in microseconds; surface it in ms (and
        // a non-nil value is how the HUD knows to offer the ± nudge control).
        info.subtitleDelayMs = player.currentVideoSubTitleDelay / 1000

        return info
    }

    /// VLC retimes subtitles live (microsecond-precision). Used by the HUD to
    /// diagnose / work around the segmented-WebVTT desync on the AVKit path by
    /// proving the SRT itself is correctly timed under VLC.
    public func setSubtitleDelay(milliseconds: Int) async {
        player.currentVideoSubTitleDelay = milliseconds * 1000
    }

    /// Teardown order: detach drawable → nil delegate → stop → finish.
    ///
    /// **`player.media` is deliberately NOT nil'd.** VLCKit 4.x's `media` getter wraps
    /// `libvlc_media_player_get_media()` and calls `libvlc_media_retain` on the result
    /// *without a null check*. VLC's PiP controller polls the drawable's media-controller
    /// (`mediaLength()` reads `player.media`) off the main thread, and that poll can fire
    /// during teardown — if the media were nil'd here, the getter would retain NULL and
    /// abort (`Assertion failed: (p_md)`, media.c). Leaving the media set keeps the getter
    /// valid; the player releases it on dealloc once the engine and the video host's
    /// coordinator both drop their references. Detaching the drawable first also stops the
    /// vout. AVKit never hits this — it owns its PiP internally and reads no VLC media
    /// off-thread. (Host-side: `VLCVideoHost.Coordinator.mediaLength()` additionally gates
    /// the getter on `hasVideoOut`.)
    public func teardown() async {
        loadWatchdog.disarm()
        progressTask?.cancel()
        progressTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        pendingSeekMs = nil
        rateFlushAnchorMs = nil
        player.drawable = nil
        player.delegate = nil
        player.stop()
        currentMedia = nil
        continuation.finish()
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
        media.addOption(":network-caching=\(Self.cacheDepthMs(for: asset.hints))")
        // iOS gives VLC's text renderers no font provider, so without explicit fonts
        // they render nothing ("can't find selected font provider"). libass (ASS/SSA)
        // and the simple SRT renderer are separate subsystems with separate options:
        // libass scans `ssa-fontsdir`, the simple renderer takes a single `freetype-font`.
        if let fontsDir = asset.subtitleFontsDirectoryURL?.path {
            media.addOption(":ssa-fontsdir=\(fontsDir)")
        }
        if let fontPath = asset.subtitleFontURL?.path {
            media.addOption(":freetype-font=\(fontPath)")
        }
        // VLC's freetype renderer (embedded plain-text subs), pinned to the boxless
        // black-outline look of `SubtitleStyle.standard`. The fill dim is the real
        // change — the default 0xFFFFFF reads as peak white next to tone-mapped HDR
        // video. Background/outline match VLC's *desktop* defaults, but are set
        // explicitly because the iOS build's defaults have never been device-verified
        // (a dim fill WITHOUT a border would be worse than the old pure white).
        // ASS/SSA keep their authored styles (libass ignores freetype-*).
        media.addOption(":freetype-color=\(SubtitleStyle.standard.foreground.rgb24)")
        media.addOption(":freetype-background-opacity=0")
        media.addOption(":freetype-outline-color=\(SubtitleStyle.standard.outline.rgb24)")
        media.addOption(":freetype-outline-thickness=4")
        if let headers = asset.headers {
            // Header values originate from the trusted Jellyfin server response and
            // are interpolated verbatim into VLC option strings (no delimiter sanitization).
            if let ua = headers["User-Agent"] {
                media.addOption(":http-user-agent=\(ua)")
            }
            if let ref = headers["Referer"] {
                media.addOption(":http-referrer=\(ref)")
            }
        }
        // Caller-supplied verbatim media options (e.g. SMB credentials). Opaque to
        // the engine and applied last so they can override the defaults above.
        // NEVER logged — an entry here can carry a password.
        for option in asset.vlcOptions ?? [] {
            media.addOption(option)
        }
    }

    /// Poll the live player clock every 500ms (matching `AVKitEngine`'s observer
    /// cadence) and publish a `.playing` beat while playback is active. Stays silent
    /// while paused — pause/seek emit their own beat — so a paused stream doesn't
    /// flood progress reports, exactly like AVKit's periodic observer (which doesn't
    /// fire while time is frozen).
    private func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                // Re-assert the no-engine-subtitle latch every tick. VLC can SELECT a
                // late-discovered embedded text track at any point during the demux — a selection
                // change the add-time `mediaPlayerTrackAdded` hook never sees. If the app is drawing
                // its own sidecar (or subs are Off), force the engine subtitle back off so it can't
                // render THROUGH the overlay. Guaranteed self-healing within one tick; the
                // `mediaPlayerTrackSelected` delegate below is the instant path. Runs FIRST so the
                // rate-flush bridge's `continue` can't starve it for the hold (a re-decode can
                // silently re-select an embedded track during that window).
                if self.subtitlesDisabled, self.player.textTracks.contains(where: { $0.isSelected }) {
                    self.player.deselectAllTextTracks()
                }
                // Rate-change flush bridge: while VLC re-decodes at the new rate its clock holds at
                // the flush point and it transiently reports not-playing. Surface that as buffering
                // (the app debounces it — invisible if quick, a spinner only if it runs long)
                // instead of a silently frozen counter, re-asserting the rate so the re-decode runs
                // at the new speed, and resume once the clock advances past the hold (or the budget
                // elapses). Runs before the isPlaying guard because the re-decode reports not-playing.
                if let anchor = self.rateFlushAnchorMs {
                    self.rateFlushTicks += 1
                    self.reassertRateIfNeeded()
                    if Self.flushBridgeShouldResume(now: self.player.time.intValue, anchor: anchor, ticks: self.rateFlushTicks) {
                        self.rateFlushAnchorMs = nil
                    } else {
                        self.emitBuffering(positionMs: anchor)
                        continue
                    }
                }
                guard self.player.isPlaying else { continue }
                // Re-assert the playback rate now the input is live. libvlc applies `rate` to
                // the active input, so the speed chosen before the demux was up (the
                // fresh-engine re-apply right after play()) was dropped — this is where it sticks.
                self.reassertRateIfNeeded()
                // Hold beats until the resume seek has applied, so the first beat reports
                // the resume position rather than the pre-seek clock (no 0:00 flash).
                guard self.pendingStartMs == nil else { continue }
                // Suppress the transient clock VLC reports right after a user seek until it
                // converges on the requested target (±3s tolerates a keyframe-snapped
                // landing); a ~5s fallback resumes live tracking if it never lands exactly.
                if let target = self.pendingSeekMs {
                    self.pendingSeekPolls += 1
                    if Self.seekHasSettled(now: self.player.time.intValue, target: target, polls: self.pendingSeekPolls) {
                        self.pendingSeekMs = nil
                    } else {
                        continue
                    }
                }
                self.emitPosition(isPlaying: true, positionMs: self.player.time.intValue)
                // Re-emit the inventory once VLC settles the default selection, so the
                // menus check the playing track and the chip shows its name.
                if !self.didEmitSettledInventory,
                   self.player.audioTracks.contains(where: { $0.isSelected }) {
                    self.didEmitSettledInventory = true
                    self.emitReady()
                }
            }
        }
    }

    /// The duration (ms) to publish: the container's real length once libvlc resolves it, else the
    /// read-rate runtime estimate for incomplete media (captured once and held), else 0 (→
    /// `.indefinite`). See `estimateDurationMs` / `lastEstimateMs`.
    private func effectiveDurationMs() -> Int32 {
        guard let media = currentMedia else { return 0 }
        let real = media.length.intValue
        if real > 0 { return real }
        // No container length (incomplete/truncated media). Capture the read-rate estimate ONCE,
        // while settled (no pending seek/resume/flush — a seek re-reads bytes and skews the demux
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
               playedMs: player.time.intValue,
               demuxReadBytes: Int(UInt32(bitPattern: media.statistics.demuxReadBytes))
           ) {
            lastEstimateMs = est
        }
        return lastEstimateMs
    }

    /// Publish a single position beat. The ONLY thing gated is `player.time` reading the
    /// VLC_TICK_INVALID sentinel (-1) before the first frame — emitting that would snap the
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
        guard currentMedia != nil,
              let beat = Self.liveBeat(isPlaying: isPlaying, positionMs: positionMs, durationMs: effectiveDurationMs())
        else { return }
        loadWatchdog.disarm()   // a real position beat = frames are rendering, the load is alive
        continuation.yield(beat)
    }

    /// Publish a buffering beat (same position-guarding as `emitPosition`). Used by the rate-change
    /// flush bridge so a re-decode hold reads as buffering (the app debounces it) rather than a
    /// frozen position.
    private func emitBuffering(positionMs: Int32) {
        guard currentMedia != nil, positionMs >= 0 else { return }
        continuation.yield(.buffering(
            position: Self.vlcTimeToCMTime(ms: positionMs),
            duration: Self.vlcDurationToCMTime(ms: effectiveDurationMs()),
            buffered: nil
        ))
    }

    /// Emit `.ready` with the current duration + track inventory. Called at
    /// `mediaPlayerLengthChanged`, when a text track appears, and from the poll after VLC settles
    /// the default track selection (so the menus reflect the playing track). Not gated on a known
    /// length: the app's `.ready` handler only adopts the track inventory (duration rides the
    /// position beats), so publishing tracks while the length is still unknown is correct — the
    /// duration carried here is `.indefinite` until `mediaPlayerLengthChanged` resolves it.
    private func emitReady() {
        guard currentMedia != nil else { return }
        loadWatchdog.disarm()   // tracks/length resolved = the demux is progressing, the load is alive
        continuation.yield(.ready(
            duration: Self.vlcDurationToCMTime(ms: effectiveDurationMs()),
            tracks: buildTrackInventory()
        ))
    }

    private func buildTrackInventory() -> TrackInventory {
        let audioTracks = player.audioTracks.map { t in
            Self.buildAudioTrack(id: t.trackId, name: t.trackName, language: t.language)
        }
        let subtitleTracks = player.textTracks.map { t in
            Self.buildSubtitleTrack(id: t.trackId, name: t.trackName, language: t.language)
        }
        // Surface VLC's own default selection so the menus check the active track
        // at start (AVKit's inventory already does this; without it the VLC path
        // opened with every track unchecked). A subtitle is often unselected → nil.
        let selectedAudioID = player.audioTracks.first(where: { $0.isSelected }).map { TrackID.vlc($0.trackId) }
        let selectedSubtitleID = player.textTracks.first(where: { $0.isSelected }).map { TrackID.vlc($0.trackId) }
        return TrackInventory(
            audio: audioTracks,
            subtitles: subtitleTracks,
            selectedAudioID: selectedAudioID,
            selectedSubtitleID: selectedSubtitleID
        )
    }

    /// Idempotent one-time setter for VLC's events configuration. The first access
    /// runs the closure exactly once (Swift `static let` semantics); later accesses
    /// are no-ops. Routing all configuration through this guarantees the legacy
    /// events config (main-queue delegate delivery) is installed before any
    /// `VLCMediaPlayer` is created — which the `assumeIsolated` delegate hops require.
    private static let _eventsConfigured: Void = {
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()
    }()

    /// Ensures VLC delivers delegate callbacks on the main queue. Idempotent and
    /// safe to call multiple times; `init()` invokes it automatically, so an
    /// explicit app-launch call is optional belt-and-suspenders.
    public static func configureVLCEvents() {
        _ = _eventsConfigured
    }

    // MARK: - Pure static helpers (testable without a live VLC decode)

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
    nonisolated private static let estimateFloorMs: Int32 = 3_000

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
    /// Skips only when the position is libvlc's pre-first-frame sentinel (`player.time` == -1
    /// before the first frame) — emitting that would snap `lastPosition` to 0:00 and risk
    /// losing the resume point. An UNKNOWN length (`durationMs` <= 0) does NOT skip: readiness
    /// is "frames are rendering" (a valid position), not "duration is known", so the beat ships
    /// with an `.indefinite` duration and the player leaves `.loading` even on incomplete media
    /// whose length never resolves. Pure so the gate is testable without a live decode.
    nonisolated static func liveBeat(isPlaying: Bool, positionMs: Int32, durationMs: Int32) -> PlaybackState? {
        guard positionMs >= 0 else { return nil }
        return positionState(isPlaying: isPlaying, positionMs: positionMs, durationMs: durationMs)
    }

    /// Whether a post-seek poll should resume publishing live position beats: VLC's clock
    /// has converged on the requested target (±3s, tolerating a keyframe-snapped landing),
    /// or the fallback poll budget elapsed so live tracking resumes even if it never lands
    /// exactly. Pure so the seek-overshoot guard can be tested without a live player.
    static func seekHasSettled(now: Int32, target: Int32, polls: Int) -> Bool {
        abs(now - target) <= 3_000 || polls >= 10
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

    /// Whether the rate-change flush bridge should stop holding and resume live position tracking:
    /// VLC's clock has advanced past the flush anchor (the re-decode produced output at the new
    /// rate), or the poll budget elapsed (resume even if it never cleanly advances, so the counter
    /// can't hold forever). The +200ms margin tolerates clock jitter at the hold point; 8 ticks ≈
    /// 4s at the 500ms poll. Pure so the gate is testable without a live decode. Mirrors `seekHasSettled`.
    static func flushBridgeShouldResume(now: Int32, anchor: Int32, ticks: Int) -> Bool {
        now > anchor + 200 || ticks >= 8
    }

    nonisolated static func positionState(isPlaying: Bool, positionMs: Int32, durationMs: Int32) -> PlaybackState {
        let position = vlcTimeToCMTime(ms: positionMs)
        let duration = vlcDurationToCMTime(ms: durationMs)
        // buffered: nil — libvlc exposes no loaded-range query; its small network
        // cache wouldn't meaningfully feed the bar's instant-seek layer anyway.
        return isPlaying
            ? .playing(position: position, duration: duration, buffered: nil)
            : .paused(position: position, duration: duration, buffered: nil)
    }

    /// `id` is VLC's own `trackId` string; it is tagged `.vlc` so it can never be
    /// confused with an AVKit option index or a Jellyfin stream index.
    public static func buildAudioTrack(id: String, name: String, language: String?) -> AudioTrack {
        AudioTrack(id: .vlc(id), displayName: name, languageCode: language)
    }

    public static func buildSubtitleTrack(id: String, name: String, language: String?) -> SubtitleTrack {
        SubtitleTrack(id: .vlc(id), displayName: name, languageCode: language, isForced: false)
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCKitEngine: VLCMediaPlayerDelegate {

    // MARK: — State changes

    /// VLC 4.x delivers state directly as `VLCMediaPlayerState` (NOT a Notification).
    /// In 4.x the legacy events config routes this callback to the main queue.
    /// Swift cannot prove that, so we assert isolation via `assumeIsolated`.
    public nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        MainActor.assumeIsolated {
            handleStateChanged(newState)
        }
    }

    // MARK: — Duration / track availability

    /// Delivered as Int64 ms directly (not a Notification). Used to emit
    /// `.ready` once duration is known.
    public nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        MainActor.assumeIsolated {
            handleLengthChanged(length)
        }
    }

    /// A new track became available for selection. Embedded tracks can surface *after* the
    /// initial `.ready` inventory (VLC discovers them as the demux progresses), so re-emit
    /// when a text track appears and the subtitle chip picks it up. (External sidecar subs
    /// are rendered client-side, not slaved to the player — see `PlayerViewModel.makeAsset`.)
    /// Audio/video adds are ignored: the inventory already carries them and the audio-chip
    /// default is handled by the progress poll's settle re-emit.
    public nonisolated func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        guard trackType == .text else { return }
        MainActor.assumeIsolated {
            // VLC auto-selects a newly-discovered default/forced embedded sub. If the app
            // asked for NO engine subtitle (it's drawing an external sidecar, or subs are
            // Off), re-assert that here so the late track can't render through the overlay.
            if subtitlesDisabled { player.deselectAllTextTracks() }
            emitReady()
        }
    }

    /// VLC selected (or deselected) a track. `mediaPlayerTrackAdded` only fires when a track first
    /// appears — VLC can auto-SELECT an already-discovered embedded text track *later* (default/
    /// forced flags resolved as the demux settles), which that hook never sees and which would
    /// render through the client sidecar overlay. When the app wants no engine subtitle, re-assert
    /// the deselect the instant a text track is selected. Our own `deselectAllTextTracks()` fires
    /// this again with a nil `selectedId`, so gating on `selectedId != nil` avoids a feedback loop.
    public nonisolated func mediaPlayerTrackSelected(_ trackType: VLCMedia.TrackType, selectedId: String?, unselectedId: String?) {
        guard trackType == .text, selectedId != nil else { return }
        MainActor.assumeIsolated {
            if subtitlesDisabled { player.deselectAllTextTracks() }
        }
    }

    // MARK: — Private (MainActor, called via assumeIsolated)

    private func handleStateChanged(_ state: VLCMediaPlayerState) {
        switch state {
        case .opening:
            continuation.yield(.loading)
        case .stopped, .stopping:
            // Natural end-of-stream. During teardown the delegate is nilled BEFORE
            // player.stop(), so this branch is never reached from teardown — no
            // spurious .ended beat.
            loadWatchdog.disarm()
            if currentMedia != nil {
                continuation.yield(.ended)
            }
        case .error:
            loadWatchdog.disarm()   // libvlc surfaced the failure itself; don't also time out
            continuation.yield(.failed(.assetNotPlayable))
        case .buffering, .playing, .paused:
            // Deliberately ignored for BEATS. VLC 4.x sticks in `.buffering` during normal
            // playback and rarely emits `.playing`/`.paused` correctly
            // (VideoLAN VLCKit#578/#128/#80). Progress and play/pause state come
            // from `startProgressPolling()` reading `player.isPlaying`, not from
            // these unreliable transitions.
            // BUT they're the "input opened, data is flowing" signal, so they disarm the load
            // watchdog — the deadline only guards "stuck opening a dead mount". Without this, a
            // remote pause landing before the first frame (pause() emits nothing: player.time is
            // the -1 sentinel) or a slow first frame would let the deadline fire on healthy media.
            loadWatchdog.disarm()
        @unknown default:
            break
        }
    }

    private func handleLengthChanged(_ lengthMs: Int64) {
        guard lengthMs > 0 else { return }
        emitReady()
    }
}

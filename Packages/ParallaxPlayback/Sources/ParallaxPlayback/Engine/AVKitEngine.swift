import Foundation
import AVFoundation
import CoreMedia
import ParallaxCore

@MainActor
public final class AVKitEngine: NSObject, PlaybackEngine, AVPlayerHosting {
    public nonisolated let id: PlaybackEngineID = .avKit
    public nonisolated let capabilities = PlaybackEngineCapabilities(
        supportsPiP: true,
        supportsVideoAirPlay: true,
        supportsNowPlayingIntegration: true
    )

    public nonisolated let state: AsyncStream<PlaybackState>
    private nonisolated let continuation: AsyncStream<PlaybackState>.Continuation

    private let player = AVPlayer()
    public nonisolated var avPlayer: AVPlayer { player }

    /// `AVAssetImageGenerator` issues fresh range reads for its still — over the SMB bridge
    /// route those queue behind (and ahead of) the player's own reads on the same reader. See
    /// the protocol doc.
    public nonisolated let captureFramePerformsIO = true

    /// Injected buffering profile — see `StartupTuning`. `.systemDefault` (every field
    /// `nil`) applies nothing in `load()`, so the shipping default is byte-identical to
    /// today's behavior.
    private let tuning: StartupTuning

    /// Live playback clock for the client-side subtitle overlay.
    public nonisolated var currentTime: CMTime { player.currentTime() }

    private var currentItem: AVPlayerItem?
    private var pendingStartTime: CMTime?
    /// The user-selected playback speed. Stored so `play()` (which resumes at
    /// `defaultRate`) honors it, and so a mid-playback change applies immediately.
    private var desiredRate: Float = 1
    private var statusObservation: NSKeyValueObservation?
    /// Player-level (survives reloads — installed once in `init`): flips of
    /// `timeControlStatus` drive the `.buffering` beats. The periodic time
    /// observer can go quiet while playback is stalled (time isn't advancing),
    /// so a stall must be reported edge-triggered, not poll-discovered.
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    /// Surfaces a `.failed` if the item never becomes playable within the deadline — `load()` never
    /// throws here (every AVFoundation setter is non-throwing), so without this a dead URL / stuck
    /// segment fetch would strand the player on the loading scrim forever. Armed in `play()`,
    /// disarmed by the first beat / `.ready` / terminal state / detach. See `LoadWatchdog`.
    private let loadWatchdog = LoadWatchdog()
    /// Bounds a mid-playback stall: a network death after the first frame parks the player in
    /// `.waitingToPlayAtSpecifiedRate` (→ `.buffering`) retrying a dead socket with no AVFoundation
    /// timeout — the SMB bridge makes this eternal (it silently resets TCP on NAS loss and AVPlayer
    /// retries the live listener forever). Armed on entering `.waitingToPlayAtSpecifiedRate`,
    /// disarmed by any transport beat / terminal state / detach; expiry yields
    /// `.failed(.networkStalled)`. `lazy` so the
    /// `onExpiry` closure can capture `self`. See `StallWatchdog`.
    private lazy var stallWatchdog = StallWatchdog { [weak self] in self?.handleStallTimeout() }
    /// Loads the media-selection inventory off the actor. Held so `teardown()`
    /// can cancel it — otherwise a slow `loadMediaSelectionGroup` keeps the
    /// AVPlayerItem (and its open network connection) alive after dismissal.
    private var inventoryTask: Task<Void, Never>?

    /// The asset declared that the app draws every subtitle itself
    /// (`PlayableAsset.engineSubtitlesDisabled`), so AVFoundation must never render a
    /// legible option. Unlike VLC there is no `:no-spu` equivalent, so enforcement is a
    /// deselect at each point AVFoundation re-applies its automatic selection criteria —
    /// when the media selection groups load, on `.ready`, and after any audible selection
    /// (documented: criteria re-apply on a selection in another group) — plus
    /// `setSubtitleTrack` refusing to select for the lifetime of the asset. Set on each
    /// `load()`.
    private var engineSubtitlesDisabled = false
    /// The `load()`-time deselect, held so `teardown()`/a reload can cancel it —
    /// same rationale as `inventoryTask`.
    private var subtitleDeselectTask: Task<Void, Never>?

    /// How many `seek(to:)` calls have been issued and not yet returned from
    /// `await player.seek`. The seek-settle contract's whole state on this engine (see
    /// `PlaybackState`): while it is non-zero, `player.currentTime()` is the clock the seek is
    /// moving away from — AVPlayer reports the transitional clock through the periodic observer
    /// and the `timeControlStatus` KVO with no marker of its own — so every beat those publish
    /// is `.stale`. The only `.projected` beat this engine makes is `seek()`'s own pre-seek
    /// target echo, which carries the request rather than the clock.
    /// A count, not a flag, because overlapping seeks each own one: only the drain back to
    /// zero (the LATEST seek returning) can produce an `.observed` beat.
    ///
    /// `private(set)` rather than private so a test can prove a seek really is outstanding
    /// before asserting what the beats published inside that window are labelled — otherwise
    /// a seek that had already completed would pass the assertion vacuously.
    private(set) var inFlightSeeks = 0

    /// Which BATCH of outstanding seeks a completion belongs to. Every seek — the load-time
    /// resume one and every ordinary `seek(to:)` — captures this before it awaits, and its
    /// completion is a no-op unless it still matches. Two events close a whole batch at once
    /// and bump it: `detachCurrentItem` (the item they were queued against is gone) and a
    /// seek finishing as the newest one (AVFoundation has superseded every older seek, so
    /// their slots are dead — see `seek(to:)`).
    ///
    /// A generation rather than a flag because a seek's completion outlives the batch it was
    /// queued in, and AVFoundation promises nothing about resuming one when the item is
    /// replaced: a `player.seek` left hanging by a reload keeps its slot forever, so
    /// `inFlightSeeks` never drains and every beat of the NEW stream ships `.stale` — a hold
    /// on the app side that only its watchdog can end. Zeroing without the stamp is worse
    /// than not zeroing: the abandoned completion would then drive the count NEGATIVE, and
    /// `inFlightSeeks == 0` would be false for the rest of the session.
    ///
    /// `private(set)` so a test can capture a generation, discard the item, and drive the
    /// abandoned completion through `seekDidFinish(generation:)` — the race itself is not
    /// something a test can hold open against real AVFoundation.
    private(set) var seekGeneration = 0

    /// Issue order for `seek(to:)`, so a completion can tell "I am the newest seek" from "a
    /// newer one has already been issued". The COUNT alone cannot: it says how many seeks are
    /// outstanding, not which of them AVFoundation is now honouring.
    private var latestSeekSerial = 0

    /// Where the position of a CLOCK-READ beat about to ship comes from (see
    /// `PositionProvenance`). Only two answers exist here: with no seek outstanding
    /// `player.currentTime()` is `.observed`, and with one outstanding it is `.stale` — never
    /// `.projected`, because unlike VLC this engine has no extrapolation to publish; the clock
    /// simply keeps reading the pre-seek value until AVPlayer moves it.
    ///
    /// AVKit's `.observed` is the WEAK form — "no seek call is outstanding", i.e. AVPlayer
    /// returned from the latest one — not VLC's "the clock converged on the target";
    /// `AVPlayer.seek` reporting `finished` IS the strongest completion signal this engine has.
    private var clockProvenance: PositionProvenance { inFlightSeeks == 0 ? .observed : .stale }

    // Server-side track metadata for the current asset, used to label tracks a
    // transcode manifest left unnamed.
    private var mediaStreams: [MediaStreamInfo] = []
    private var defaultAudioStreamIndex: Int?
    private var defaultSubtitleStreamIndex: Int?

    public init(tuning: StartupTuning = .systemDefault) {
        self.tuning = tuning
        let (stream, continuation) = PlaybackStateStream.makeStream()
        self.state = stream
        self.continuation = continuation
        super.init()
        // Unlike the item-status KVO (delivered on the main run loop), AVPlayer
        // flips timeControlStatus from its own internal queue — hop to main
        // instead of assuming isolation.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleTimeControlChange() }
            }
        }
    }

    /// Emits the beat matching the player's transport state the moment it flips:
    /// `.waitingToPlayAtSpecifiedRate` → `.buffering` (mid-stream stall — a seek
    /// past the buffer or a network underrun), `.playing` → `.playing` (snappy
    /// stall-clear instead of waiting for the next periodic tick). `.paused` is
    /// owned by `pause()` and the periodic observer.
    private func handleTimeControlChange() {
        guard let item = currentItem, item.status == .readyToPlay else { return }
        loadWatchdog.disarm()   // transport is responding — the load is alive
        let position = player.currentTime()
        let buffered = Self.bufferedEnd(of: item, at: position)
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            stallWatchdog.arm()   // a mid-stream stall — bound it so a dead socket can't buffer forever
            continuation.yield(.buffering(position: position, duration: item.duration,
                                          buffered: buffered, provenance: clockProvenance))
        case .playing:
            stallWatchdog.disarm()   // frames are flowing again — the stall cleared
            continuation.yield(.playing(position: position, duration: item.duration,
                                        buffered: buffered, provenance: clockProvenance))
        case .paused:
            stallWatchdog.disarm()   // user/transport paused — not a stall
            break
        @unknown default:
            break
        }
    }

    /// Styling for natively rendered legible tracks (direct-play embedded WebVTT —
    /// sidecar text subs never reach AVKit; the app overlay draws those). Matches
    /// `SubtitleStyle.standard`: no cue box, black uniform glyph edge, dimmed-white
    /// fill — native rendering composites into the HDR frame, where pure white is
    /// drawn at peak brightness ("only the subtitles have HDR"). Per the docs the
    /// rules apply to WebVTT only; other legible formats keep system styling. Size
    /// is left at the system default (≈5% of video height), which already scales
    /// per screen. Best-effort, not authoritative: a user-customized Subtitles &
    /// Captioning style (Settings > Accessibility) can take precedence over these
    /// rules — by iOS design, not a bug here.
    private static let subtitleStyleRules: [AVTextStyleRule]? = {
        let fg = SubtitleStyle.standard.foreground
        let clear = [0, 0, 0, 0] as [NSNumber]
        let attributes: [String: Any] = [
            kCMTextMarkupAttribute_BackgroundColorARGB as String: clear,
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: clear,
            kCMTextMarkupAttribute_CharacterEdgeStyle as String:
                kCMTextMarkupCharacterEdgeStyle_Uniform as String,
            kCMTextMarkupAttribute_ForegroundColorARGB as String:
                [fg.alpha, fg.red, fg.green, fg.blue].map { NSNumber(value: $0) },
        ]
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
    }()

    public func load(_ asset: PlayableAsset) async throws {
        // Reload-safe: a transcode track switch loads a NEW asset into this same
        // engine, keeping the AVPlayer + its mounted layer (so the swap holds the
        // last frame instead of blinking to black). Detach the previous item's
        // observers first — otherwise the periodic-time observer leaks and the KVO /
        // end observers double-fire.
        detachCurrentItem()
        continuation.yield(.loading)
        pendingStartTime = asset.startTime
        engineSubtitlesDisabled = asset.engineSubtitlesDisabled
        mediaStreams = asset.mediaStreams
        defaultAudioStreamIndex = asset.defaultAudioStreamIndex
        defaultSubtitleStreamIndex = asset.defaultSubtitleStreamIndex

        let urlAsset = AVURLAsset(url: asset.url)
        let item = AVPlayerItem(asset: urlAsset)
        item.textStyleRules = Self.subtitleStyleRules
        // Startup tuning (see `StartupTuning`) applied HERE — before `replaceCurrentItem`
        // and before the pre-ready resume-seek block below is queued — and deliberately
        // not moved past either: the resume seek is a device-diagnosed livelock fix
        // (see the comment on `pendingStartTime` below) and must not be reordered or
        // interleaved with these knob applications. `.systemDefault` (every field nil)
        // applies nothing, leaving both AVPlayer properties untouched.
        Self.applyTuning(tuning, to: item, player: player)
        currentItem = item

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            // KVO delivers on the main run loop for an AVPlayerItem created here.
            MainActor.assumeIsolated {
                self?.handleStatusChange(item)
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.emitTimeUpdate(at: time)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEnded()
            }
        }


        player.replaceCurrentItem(with: item)

        // First of the two deselects: the media selection groups resolve well before
        // `.readyToPlay`, and AVPlayer's automatic selection has already run by then —
        // waiting for readiness would let the first frames ship with a subtitle burned
        // over our own overlay.
        if engineSubtitlesDisabled {
            subtitleDeselectTask = Task { [weak self] in
                await self?.deselectLegible(of: item)
            }
        }

        // The resume seek must land BEFORE readiness, not on .readyToPlay: a
        // pre-ready seek queues against the item and aims the player's FIRST
        // media request at the resume offset. Seeking only after .readyToPlay
        // made AVPlayer load position 0 first (readiness requires media there)
        // and then jump — but a Jellyfin transcode job is producing segments AT
        // the resume offset, and every out-of-window segment request kills and
        // restarts its ffmpeg job. On a 4K stream-copy each restart outran the
        // 3s segment timeout (-12889 "no response for media file") in a
        // kill/restart livelock: black screen, no audio, transport stuck in
        // waiting(minimize stalls) with the buffer parked at the resume offset
        // (device-diagnosed 2026-06-11). Default tolerance — segment-level
        // accuracy is right for resume, and frame-exact targets can't even
        // start on a mid-GOP stream-copied segment.
        if let start = pendingStartTime {
            pendingStartTime = nil
            // Counted exactly like `seek(to:)` (see `inFlightSeeks`): until this lands,
            // `player.currentTime()` reads 0, and the periodic observer starts publishing the
            // moment the item is ready. Labelled `.observed`, those beats tell a consumer the
            // resume already happened at 00:00 — which after a transcode re-anchor
            // (`load(startTime: B)`) is precisely the evidence that drops a held seek target
            // and snaps the bar to zero.
            let generation = seekGeneration
            inFlightSeeks += 1
            item.seek(to: start) { [weak self] _ in
                // Delivered on an arbitrary queue; the counter is main-actor state.
                Task { @MainActor in self?.seekDidFinish(generation: generation) }
            }
        }
    }

    /// Closes one seek's slot in `inFlightSeeks`. A completion from a DISCARDED item is
    /// ignored: `detachCurrentItem` already closed every window that item owned, and the
    /// count now belongs to the stream playing.
    ///
    /// Internal rather than private so the abandoned-completion case is testable at all — see
    /// `seekGeneration`.
    func seekDidFinish(generation: Int) {
        guard generation == seekGeneration else { return }
        inFlightSeeks -= 1
    }

    /// Closes EVERY outstanding seek slot and stamps the calls still in flight as superseded,
    /// so their late completions land on a batch that is no longer theirs (rather than driving
    /// the count negative). Shared by `detachCurrentItem` — the item they belonged to is gone —
    /// and by the newest seek finishing, where AVFoundation has demonstrably moved past every
    /// older request, including a load-time resume that never resolved.
    private func supersedeOutstandingSeeks() {
        seekGeneration &+= 1
        inFlightSeeks = 0
    }

    public func play() async {
        player.playImmediately(atRate: desiredRate)
        // Deadline the load: a URL that never reaches `.readyToPlay` (dead mount, stuck segment)
        // can't strand the player on the scrim. Disarmed by the first beat / `.ready` / terminal /
        // detach.
        loadWatchdog.arm { [weak self] in self?.handleLoadTimeout() }
    }

    /// The item never became playable within the watchdog deadline — surface `.failed` so the
    /// error scrim takes over instead of an endless spinner. Guarded by `currentItem` so a beat
    /// that already disarmed makes this a no-op.
    ///
    /// `.loadTimedOut`, not `.assetNotPlayable`: nothing here says the asset is broken, and
    /// borrowing that case put "Couldn't decode this file" on a server that was merely slow.
    /// Internal so a test can drive the expiry without waiting out the real deadline.
    @discardableResult
    func handleLoadTimeout() -> PlaybackDebugInfo? {
        guard let item = currentItem else { return nil }
        let snapshot = logWatchdogExpiry("load", of: item)
        continuation.yield(.failed(.loadTimedOut))
        return snapshot
    }

    /// A mid-playback stall (`.buffering`) never recovered within the watchdog deadline — surface
    /// `.failed(.networkStalled)` so the "stream stalled and didn't recover" scrim + manual retry
    /// take over instead of an eternal spinner. Guarded by `currentItem` so a beat that already
    /// disarmed makes this a no-op (mirrors `handleLoadTimeout`).
    @discardableResult
    func handleStallTimeout() -> PlaybackDebugInfo? {
        guard let item = currentItem else { return nil }
        let snapshot = logWatchdogExpiry("stall", of: item)
        continuation.yield(.failed(.networkStalled))
        return snapshot
    }

    /// A watchdog giving up is the one moment where "it just spun forever" becomes a report,
    /// and the useful half is what the engine was doing when it gave up. Read SYNCHRONOUSLY,
    /// before the `.failed` above reaches the app: that beat is what tears the engine down (a
    /// `.loadTimedOut` on an MP4 reroutes to VLC, which retires this engine outright), so a
    /// snapshot deferred into a `Task` was read after `currentItem` was already nil and logged
    /// a line of dashes — empty in exactly the case it was written for. Only the
    /// media-selection half of `debugSnapshot()` needs an await, and none of it is in here.
    ///
    /// Returns what it logged so a test can assert on the diagnosis rather than on the log.
    @discardableResult
    private func logWatchdogExpiry(_ kind: String, of item: AVPlayerItem) -> PlaybackDebugInfo {
        let snapshot = syncSnapshot(of: item)
        Log.playback.error(
            """
            AVKit \(kind, privacy: .public) watchdog expired: \(snapshot.logSummary, privacy: .public) \
            hlsErrors=\(snapshot.errorLogDetail, privacy: .private)
            """
        )
        return snapshot
    }

    public func pause() async {
        player.pause()
        stallWatchdog.disarm()   // an explicit pause is never a stall
        if let item = currentItem, item.status == .readyToPlay {
            let position = player.currentTime()
            continuation.yield(.paused(
                position: position,
                duration: item.duration,
                buffered: Self.bufferedEnd(of: item, at: position),
                provenance: clockProvenance
            ))
        }
    }

    public func setRate(_ rate: Float) async {
        desiredRate = rate
        // defaultRate is the rate play() resumes at; rate is the live rate.
        player.defaultRate = rate
        // Only push the live rate when already playing — setting `rate` while
        // paused would start playback unexpectedly.
        if player.timeControlStatus == .playing {
            player.rate = rate
        }
    }

    /// **Seek-settle contract (see `PlaybackEngine.seek(to:)`).** AVKit's `.observed` is the
    /// WEAK form: "no `seek(to:)` call is outstanding", i.e. AVPlayer returned
    /// `finished == true` from the latest one. That is the strongest completion signal this
    /// engine has — there is no clock-convergence test like VLC's, and AVPlayer's default
    /// (efficient) tolerance means the landing can sit a segment away from the request. So an
    /// `.observed` beat here promises the seek RESOLVED, not that `position` equals the target.
    ///
    /// The window this opens splits by beat kind. The pre-seek echo below carries the TARGET,
    /// so it is `.projected` — display-safe, and the only forward guess this engine makes.
    /// Everything else published inside the window (the periodic observer's ticks, the
    /// `timeControlStatus` KVO's edges, a `pause()` landing here) carries
    /// `player.currentTime()`, which still reads the PRE-seek clock: `.stale`, shown nowhere.
    /// A superseded seek observes nothing: the newest call owns every subsequent beat.
    public func seek(to time: CMTime) async {
        // The protocol documents this call as a no-op with no item loaded, and without the
        // guard it was not one: the counter below opened a settle window, and AVFoundation
        // promises nothing about invoking a seek completion when there is no `currentItem` to
        // seek — an unresolved one strands the caller (a scrub commit) inside the await AND
        // leaves the slot open, which labels every later beat `.stale`. (Measured on iOS 26 it
        // resolves `finished == false`, so the leak self-closes there; that is AVFoundation's
        // choice on one OS, not a contract to build the commit path on.)
        guard currentItem != nil else { return }
        // Counted BEFORE the echo below: that beat carries the target, not an observed
        // clock, so it is the first `.projected` beat of this seek's window. Stamped with the
        // batch it is issued in, so a reload that abandons it (`detachCurrentItem`) — or a
        // newer seek that supersedes it — can reclaim the slot without this call's late return
        // double-counting. See `seekGeneration`.
        let generation = seekGeneration
        latestSeekSerial += 1
        let serial = latestSeekSerial
        inFlightSeeks += 1
        // A seek OUTSIDE the buffered range is a real media fetch, but a PAUSED
        // player performs it without ever entering .waitingToPlayAtSpecifiedRate
        // — and the drag-scrub flow always pauses before seeking, so on a
        // transcode the whole multi-second fetch would otherwise read as a dead
        // paused frame (no stall beat, no scrim). Emit the fetch explicitly.
        if let item = currentItem, item.status == .readyToPlay,
           Self.bufferedEnd(of: item, at: time) == nil {
            continuation.yield(.buffering(position: time, duration: item.duration,
                                          buffered: nil, provenance: .projected))
        }
        // Default (efficient) tolerance, not zero. Frame-exact seeking on an HLS
        // transcode is pathologically slow and can stall — it made scrubbing a 4K
        // stream feel stuck. Segment-level accuracy is right for both scrubbing and
        // the resume seek: Jellyfin's transcode is a full-timeline playlist, so
        // resume is an ordinary seek — the stream URL carries no start offset.
        let finished = await player.seek(to: time)
        // The finish rule, and all three arms matter:
        //  • `finished == false` — AVPlayer cancelled this seek for a newer one. Close only
        //    this slot; the newer call's window is what the beats belong to. A stale `.paused`
        //    beat here would wipe the newer call's `.buffering` and present a bare paused UI
        //    while its fetch is still in flight (device-found: drag → buffering → re-drag
        //    before the scrim closed showed paused, no scrim).
        //  • a stale `generation` — the item this was queued against is gone (a reload) or a
        //    newer seek already resolved. `seekDidFinish` no-ops it: the slot was reclaimed in
        //    bulk, and decrementing again would drive the count negative.
        //  • `finished` AND newest — the winner, below.
        guard finished, generation == seekGeneration, serial == latestSeekSerial else {
            seekDidFinish(generation: generation)
            return
        }
        // AVFoundation resolved the NEWEST request, which means it has moved past every older
        // one — including a load-time resume still queued against a not-yet-ready item. Their
        // slots die with this call's, because gating the beat on `inFlightSeeks == 0` instead
        // made the winner's beat depend on the LOSER's continuation having been resumed first:
        // a paused player then published no post-seek beat at all and the scrim never cleared.
        supersedeOutstandingSeeks()
        // Land the post-seek truth for a paused player: the periodic observer is
        // quiet while paused, so without this beat the stall above never clears
        // until the user resumes. (Playing/waiting outcomes are covered by the
        // timeControlStatus KVO + periodic ticks.)
        if player.timeControlStatus == .paused,
           let item = currentItem, item.status == .readyToPlay {
            let position = player.currentTime()
            continuation.yield(.paused(
                position: position,
                duration: item.duration,
                buffered: Self.bufferedEnd(of: item, at: position),
                provenance: .observed
            ))
        }
    }

    /// Whether `time` sits inside a contiguous loaded range — a seek there needs no
    /// network fetch and, on a transcode, no ffmpeg restart. The view model uses this
    /// to keep in-buffer transcode seeks in-stream and re-anchor only the out-of-buffer
    /// ones (which would otherwise restart ffmpeg mid-session → `-noaccurate_seek`
    /// subtitle drift, jellyfin#15845).
    public func isBuffered(at time: CMTime) async -> Bool {
        guard let item = currentItem else { return false }
        return Self.bufferedEnd(of: item, at: time) != nil
    }

    public func setAudioTrack(_ track: AudioTrack) async {
        await select(trackID: track.id, characteristic: .audible)
        // AVFoundation re-applies its automatic media selection criteria when a selection is
        // made in ANOTHER group, so picking the server's preferred audio track resurrects the
        // system-language legible option the two deselects had just cleared. Turning
        // `appliesMediaSelectionCriteriaAutomatically` off would stop that at the source, but
        // it is also what picks the INITIAL audio track: the app only re-points audio when the
        // Jellyfin preference disagrees with the engine's pick, so automatic selection has to
        // stay on and the deselect follows the audible selection instead.
        if engineSubtitlesDisabled, let item = currentItem {
            await deselectLegible(of: item)
        }
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) async {
        // The asset draws its own subtitles; selecting a legible option would render a
        // second copy under the client overlay. Mirrors `VLCKitEngine`'s refusal, and
        // like it applies for the lifetime of the asset — deselect (`nil`) still works.
        if track != nil, engineSubtitlesDisabled {
            Log.playback.info("setSubtitleTrack ignored: this asset renders subtitles client-side")
            return
        }
        guard let group = await legibleGroup() else { return }
        guard let track else {
            currentItem?.select(nil, in: group)
            return
        }
        await select(trackID: track.id, characteristic: .legible)
    }

    /// Turn AVFoundation's legible rendering off for `item`. Idempotent, and a no-op
    /// for an asset with no legible group at all.
    private func deselectLegible(of item: AVPlayerItem) async {
        guard let asset = item.asset as? AVURLAsset,
              let group = try? await asset.loadMediaSelectionGroup(for: .legible)
        else { return }
        // A reload/teardown between the await and here means this item is superseded.
        guard !Task.isCancelled, currentItem === item else { return }
        item.select(nil, in: group)
    }

    public func teardown() async {
        detachCurrentItem()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        engineSubtitlesDisabled = false
        mediaStreams = []
        defaultAudioStreamIndex = nil
        defaultSubtitleStreamIndex = nil
        continuation.finish()
    }

    /// Still-frame grab for SMB thumbnail backfill: reuses the already-open
    /// `AVPlayerItem` asset so the capture never re-opens the network URL. Loose
    /// keyframe tolerances keep it off the exact-decode path (which can hitch
    /// playback); failures of any kind become nil so the live session is never
    /// perturbed. Encodes via `ImageTranscode` (HEIC, JPEG fallback) — the same
    /// codec the SMB thumbnail cache writes — so the app can store the bytes
    /// as-is under a `.heic` name.
    public func captureFrame() async -> Data? {
        guard let asset = currentItem?.asset else { return nil }
        let time = player.currentTime()
        // `.invalid` / non-numeric (e.g. indefinite) clocks have no capture target;
        // a pre-ready item can also sit at a non-numeric time.
        guard time.isValid, time.isNumeric else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Land on a nearby keyframe rather than forcing an exact decode: a 1s
        // window is plenty for a browse-tile still and avoids the hitch an exact
        // tolerance can cause on a live, still-decoding item.
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // The SAME 320pt tier the browse thumbnailers produce (`AVThumbnailer`,
        // `VLCThumbnailer`): a backfilled still lands in `SMBThumbnailCache`
        // beside theirs, under a budget sized at ~30–120 KB per HEIC, and a 1280
        // still is 5–10× that. Height-bounded with a 0 width, so AVFoundation
        // scales the width from the source aspect (a portrait clip caps on its
        // long edge too, since that IS the height).
        generator.maximumSize = CGSize(width: 0, height: 320)

        do {
            // Completion-handler API rather than `image(at:)` — the async form requires `sending`
            // the generator, which a MainActor holder can't do (same wall AVThumbnailer hit).
            // Any error (no track, decode fail, cancelled generation) becomes nil — the backfill
            // is best-effort only. Cancellation of the awaiting task (stop/teardown) is forwarded
            // to AVFoundation explicitly: without it the generator's range reads keep streaming
            // after the Swift task dies. `nonisolated(unsafe)`: the handler closure is `@Sendable`
            // and the generator isn't, but `cancelAllCGImageGeneration()` is documented
            // thread-safe and this handle is used for that one call only (same idiom as
            // VLCKitEngine's player handle).
            nonisolated(unsafe) let cancellableGenerator = generator
            let cgImage: CGImage = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    generator.generateCGImageAsynchronously(for: time) { image, _, error in
                        if let image {
                            continuation.resume(returning: image)
                        } else {
                            continuation.resume(throwing: error ?? CancellationError())
                        }
                    }
                }
            } onCancel: {
                cancellableGenerator.cancelAllCGImageGeneration()
            }
            // HEIC-encoding a full frame is real CPU work; `captureFrame()`'s contract
            // (`PlaybackEngine.swift`) says it must never stall playback, and this
            // engine is pinned to `@MainActor` — so the encode has to run off-actor.
            // `CGImage`/`Data` are Sendable.
            return await Self.encode(cgImage)
        } catch {
            return nil
        }
    }

    /// Runs `ImageTranscode.encodeHEIC` off the main actor via a detached task — see
    /// `captureFrame()`. `nonisolated` because encoding touches no engine/player state.
    private nonisolated static func encode(_ image: CGImage) async -> Data? {
        await Task.detached(priority: .utility) {
            try? ImageTranscode.encodeHEIC(image)
        }.value
    }

    /// Tears down the current item's observers + async inventory load. Shared by
    /// `teardown()` (full stop) and `load()` (reload-safe: a track switch installs a
    /// new item on the same player). Deliberately does NOT finish the state stream or
    /// drop the AVPlayer, so a reload keeps the surface — and the layer — alive.
    private func detachCurrentItem() {
        // The discarded item owns every outstanding seek, and their completions may never
        // arrive (or may arrive long after the next stream is playing). Close all of those
        // windows at once — the counter would otherwise never drain and the NEXT stream's
        // beats would read `.stale` forever — and bump the generation so the abandoned
        // completions land on a slot that is no longer theirs.
        supersedeOutstandingSeeks()
        loadWatchdog.disarm()   // teardown or reload — cancel the deadline (play() re-arms on reload)
        stallWatchdog.disarm()  // and any pending mid-stream stall — a reload/teardown supersedes it
        inventoryTask?.cancel()
        inventoryTask = nil
        subtitleDeselectTask?.cancel()
        subtitleDeselectTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    public func debugSnapshot() async -> PlaybackDebugInfo {
        guard let item = currentItem else { return .empty }
        var info = syncSnapshot(of: item)
        // The one part that needs the actor: media-selection groups load asynchronously. It is
        // the debug overlay's field, not the watchdog's, which is why the two halves are split.
        // The engine's TRUE selection — what's actually audible/legible right now, which is what
        // answers "I picked a subtitle but nothing renders".
        if let asset = item.asset as? AVURLAsset {
            let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
            let selection = item.currentMediaSelection
            info.legibleOptions = legibleGroup?.options.map(\.displayName) ?? []
            info.selectedAudible = audibleGroup.flatMap { selection.selectedMediaOption(in: $0)?.displayName }
            info.selectedLegible = legibleGroup.flatMap { selection.selectedMediaOption(in: $0)?.displayName }
        }
        return info
    }

    /// Everything about `item` and the player that can be read without suspending: the whole of
    /// `logSummary`. Split out of `debugSnapshot()` so a watchdog expiry can capture its
    /// diagnosis inline, ahead of the `.failed` beat that may tear the engine down — see
    /// `logWatchdogExpiry`.
    private func syncSnapshot(of item: AVPlayerItem) -> PlaybackDebugInfo {
        var info = PlaybackDebugInfo()

        let size = item.presentationSize
        if size.width > 0, size.height > 0 {
            info.presentationWidth = Int(size.width)
            info.presentationHeight = Int(size.height)
        }

        // Access log: the negative sentinel means "not yet measured".
        if let event = item.accessLog()?.events.last {
            info.indicatedBitrate = event.indicatedBitrate > 0 ? event.indicatedBitrate : nil
            info.observedBitrate = event.observedBitrate > 0 ? event.observedBitrate : nil
            info.droppedVideoFrames = event.numberOfDroppedVideoFrames >= 0 ? event.numberOfDroppedVideoFrames : nil
            info.stallCount = event.numberOfStalls >= 0 ? event.numberOfStalls : nil
            info.bytesTransferred = event.numberOfBytesTransferred > 0 ? event.numberOfBytesTransferred : nil
        }

        // Transport truth: the discriminator for "never plays, no error".
        info.transportState = {
            switch player.timeControlStatus {
            case .paused: return "paused"
            case .playing: return "playing"
            case .waitingToPlayAtSpecifiedRate:
                let reason: String
                switch player.reasonForWaitingToPlay {
                case .toMinimizeStalls: reason = "minimize stalls"
                case .evaluatingBufferingRate: reason = "evaluating buffer rate"
                case .noItemToPlay: reason = "no item"
                case .interstitialEvent: reason = "interstitial"
                case .waitingForCoordinatedPlayback: reason = "coordinated playback"
                default: reason = "unknown"
                }
                return "waiting (\(reason))"
            @unknown default: return "unknown"
            }
        }()

        // HLS error log: segment fetch/parse failures retry silently and never
        // fail the item — a never-starting stream usually confesses here. The
        // URI is reduced to its trailing path (query stripped — that's where
        // the api_key lives) so the log names WHICH resource failed: playlist,
        // init segment, or a specific media segment.
        if let events = item.errorLog()?.events, !events.isEmpty {
            info.errorLogTail = events.suffix(3).map { e in
                let path = e.uri.flatMap(Self.redactedTail(of:)).map { " @\($0)" } ?? ""
                return "\(e.errorDomain) \(e.errorStatusCode)\(path): \(e.errorComment ?? "—")"
            }
        }

        info.itemStatus = {
            switch item.status {
            case .readyToPlay: return "ready"
            case .failed: return "failed"
            case .unknown: return "unknown"
            @unknown default: return "unknown"
            }
        }()

        if let videoTrack = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }) {
            let fps = Double(videoTrack.currentVideoFrameRate)
            info.renderedFrameRate = fps > 0 ? fps : nil
        }

        // Buffered = contiguous with the playhead ONLY. The old `.last.end - now`
        // read 1408s "buffered" while the playhead sat at 0 with nothing under
        // it — the buffered range was parked at a resume offset the playhead
        // never reached. loadedRanges carries every range so that state is
        // visible instead of averaged away.
        let now = item.currentTime()
        if CMTimeGetSeconds(now).isFinite {
            info.playheadSeconds = CMTimeGetSeconds(now)
            if let end = Self.bufferedEnd(of: item, at: now) {
                info.bufferedSeconds = max(0, CMTimeGetSeconds(end) - CMTimeGetSeconds(now))
            }
        }
        info.loadedRanges = item.loadedTimeRanges.compactMap { value in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard start.isFinite, end.isFinite else { return nil }
            return String(format: "%.1f–%.1f", start, end)
        }

        return info
    }

    // MARK: - Private

    private func handleStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            loadWatchdog.disarm()   // item is playable — the load succeeded
            // (The resume seek already happened at load time, pre-ready — see
            // load(). Seeking here re-targeted an already-position-0 player.)
            // Media-selection groups load asynchronously: the synchronous
            // `mediaSelectionGroup(forMediaCharacteristic:)` accessor is
            // deprecated and returns nil/incomplete data before the property
            // loads — which dropped the subtitle list on device. Resolve the
            // inventory on the actor, then emit .ready; duration is ready now.
            let duration = item.duration
            inventoryTask = Task { [weak self] in
                guard let self else { return }
                let tracks = await self.loadTrackInventory(of: item)
                // A reload/teardown cancels this task (see line ~271). If that
                // happened while loadTrackInventory was awaiting, a superseded
                // item must not publish a stale `.ready`.
                if Task.isCancelled { return }
                self.continuation.yield(.ready(duration: duration, tracks: tracks))
            }
        case .failed:
            // The item never became playable. Capture the concrete failure so a
            // device/sim trace can tell a genuine codec problem apart from a URL
            // load failure (401 / TLS trust / bad path / redirect) — the symptom
            // is identical ("Couldn't decode that file.") but the cause is not.
            // domain+code+localizedDescription are the actionable, token-free
            // bits; the asset URL is hashed because it embeds the api_key.
            let nsError = item.error as NSError?
            let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
            Log.playback.error(
                """
                AVPlayerItem failed: \
                domain=\(nsError?.domain ?? "nil", privacy: .public) \
                code=\(nsError?.code ?? 0, privacy: .public) \
                desc=\(nsError?.localizedDescription ?? "nil", privacy: .public) \
                underlying=\(underlying.map { "\($0.domain) code=\($0.code)" } ?? "nil", privacy: .public) \
                url=\((item.asset as? AVURLAsset)?.url.absoluteString ?? "<no-url>", privacy: .private(mask: .hash))
                """
            )
            loadWatchdog.disarm()   // the item surfaced its own failure; don't also time out
            stallWatchdog.disarm()
            continuation.yield(.failed(.assetNotPlayable))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleEnded() {
        loadWatchdog.disarm()
        stallWatchdog.disarm()
        continuation.yield(.ended)
    }

    private func emitTimeUpdate(at time: CMTime) {
        guard let item = currentItem, item.status == .readyToPlay else { return }
        loadWatchdog.disarm()   // a periodic beat = the item is live; without this a redundant
                                // play() while already playing (lock-screen/Bluetooth) re-arms the
                                // watchdog with no timeControlStatus KVO to disarm it → false timeout
        let buffered = Self.bufferedEnd(of: item, at: time)
        switch player.timeControlStatus {
        case .paused:
            stallWatchdog.disarm()
            continuation.yield(.paused(position: time, duration: item.duration,
                                       buffered: buffered, provenance: clockProvenance))
        case .waitingToPlayAtSpecifiedRate:
            stallWatchdog.arm()   // periodic tick caught a stall the KVO edge didn't (re-arm resets the clock)
            continuation.yield(.buffering(position: time, duration: item.duration,
                                          buffered: buffered, provenance: clockProvenance))
        case .playing:
            stallWatchdog.disarm()
            continuation.yield(.playing(position: time, duration: item.duration,
                                        buffered: buffered, provenance: clockProvenance))
        @unknown default:
            stallWatchdog.disarm()
            continuation.yield(.playing(position: time, duration: item.duration,
                                        buffered: buffered, provenance: clockProvenance))
        }
    }

    /// Applies `tuning`'s non-nil fields to a freshly-built item/player pair — the seam
    /// `load()` calls and tests exercise directly against a bare `AVPlayerItem`/`AVPlayer`
    /// (no network, no `.readyToPlay` needed). A `nil` field is a no-op: it leaves the
    /// corresponding property untouched rather than resetting it to a default value.
    static func applyTuning(_ tuning: StartupTuning, to item: AVPlayerItem, player: AVPlayer) {
        if let seconds = tuning.preferredForwardBufferSeconds {
            item.preferredForwardBufferDuration = seconds
        }
    }

    /// Trailing path of an HLS resource URI with the query dropped (the query
    /// is where the api_key lives): "main/123.mp4". Enough to tell playlist vs
    /// init vs media segment apart without leaking credentials.
    static func redactedTail(of uri: String) -> String? {
        guard let components = URLComponents(string: uri) else { return nil }
        let parts = components.path.split(separator: "/")
        guard !parts.isEmpty else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }

    /// End of the loaded range containing `time` — the absolute media time the
    /// contiguous buffer around the playhead extends to. A seek inside this range
    /// completes without touching the network, so it feeds the progress bar's
    /// "instant seek" layer. Nil when nothing around the playhead is buffered.
    private static func bufferedEnd(of item: AVPlayerItem, at time: CMTime) -> CMTime? {
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            if range.containsTime(time) {
                return CMTimeRangeGetEnd(range)
            }
        }
        return nil
    }

    private func loadTrackInventory(of item: AVPlayerItem) async -> TrackInventory {
        guard let asset = item.asset as? AVURLAsset else { return .empty }

        // The two groups are independent — load them concurrently so the track
        // menus surface one round-trip sooner instead of audible-then-legible.
        async let audibleTask = asset.loadMediaSelectionGroup(for: .audible)
        async let legibleTask = asset.loadMediaSelectionGroup(for: .legible)
        let audibleGroup = try? await audibleTask
        let legibleGroup = try? await legibleTask

        let audio = audioTracks(from: audibleGroup)
        let subtitles = subtitleTracks(from: legibleGroup)
        // Second of the two deselects, BEFORE the selection is read: AVPlayer can
        // re-apply its automatic legible selection between `load()` and readiness, and
        // a selection read after this is the honest one — the inventory must not ship
        // a `selectedSubtitleID` for a track nothing renders.
        if engineSubtitlesDisabled, let legibleGroup {
            item.select(nil, in: legibleGroup)
        }
        let selection = item.currentMediaSelection
        logTrackDiagnostics(audible: audibleGroup, legible: legibleGroup, audio: audio, subtitles: subtitles)
        return TrackInventory(
            audio: audio,
            subtitles: subtitles,
            selectedAudioID: Self.selectedID(in: audibleGroup, selection: selection),
            selectedSubtitleID: Self.selectedID(in: legibleGroup, selection: selection)
        )
    }

    /// The id (an `.avKitOption` index) of the option the engine is currently
    /// playing in `group`, so the UI can show it pre-selected.
    private static func selectedID(in group: AVMediaSelectionGroup?, selection: AVMediaSelection) -> TrackID? {
        guard
            let group,
            let option = selection.selectedMediaOption(in: group),
            let index = group.options.firstIndex(of: option)
        else { return nil }
        return .avKitOption(index)
    }

    /// `id` is the option's index within its *full* selection group (not the
    /// filtered display list), so `select(trackID:)` can index straight back in
    /// even though forced-only subtitles are hidden from the menu. The label
    /// runs through `JellyfinTrackMatcher`: the manifest's own name wins, else
    /// the server's stream title (a transcode often strips names), else a
    /// language/ordinal fallback — so a track never surfaces a bare "Unknown".
    private func audioTracks(from group: AVMediaSelectionGroup?) -> [AudioTrack] {
        guard let group else { return [] }
        let count = group.options.count
        var result: [AudioTrack] = []
        var ordinal = 0
        for (index, option) in group.options.enumerated() {
            ordinal += 1
            let lang = Self.language(of: option)
            // The manifest never carries codec metadata — the detail line comes
            // from the server stream when the option↔stream join is unambiguous.
            let matched = JellyfinTrackMatcher.matchedStream(
                kind: .audio,
                optionLanguage: lang,
                optionCount: count,
                streams: mediaStreams,
                defaultStreamIndex: defaultAudioStreamIndex
            )
            result.append(AudioTrack(
                id: .avKitOption(index),
                displayName: JellyfinTrackMatcher.name(
                    kind: .audio,
                    optionDisplayName: option.displayName,
                    optionLanguage: lang,
                    ordinal: ordinal,
                    optionCount: count,
                    streams: mediaStreams,
                    defaultStreamIndex: defaultAudioStreamIndex
                ),
                languageCode: lang,
                detailLabel: matched?.trackDetailLabel
            ))
        }
        return result
    }

    private func subtitleTracks(from group: AVMediaSelectionGroup?) -> [SubtitleTrack] {
        guard let group else { return [] }
        let displayed = group.options.enumerated().filter {
            !$0.element.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
        }
        var result: [SubtitleTrack] = []
        var ordinal = 0
        for (index, option) in displayed {
            ordinal += 1
            let lang = Self.language(of: option)
            let matched = JellyfinTrackMatcher.matchedStream(
                kind: .subtitle,
                optionLanguage: lang,
                optionCount: displayed.count,
                streams: mediaStreams,
                defaultStreamIndex: defaultSubtitleStreamIndex
            )
            result.append(SubtitleTrack(
                id: .avKitOption(index),
                displayName: JellyfinTrackMatcher.name(
                    kind: .subtitle,
                    optionDisplayName: option.displayName,
                    optionLanguage: lang,
                    ordinal: ordinal,
                    optionCount: displayed.count,
                    streams: mediaStreams,
                    defaultStreamIndex: defaultSubtitleStreamIndex
                ),
                languageCode: lang,
                isForced: false,
                detailLabel: matched?.trackDetailLabel,
                isExternal: matched?.isExternal ?? false,
                isSDH: matched?.isHearingImpaired ?? false
            ))
        }
        return result
    }

    private static func language(of option: AVMediaSelectionOption) -> String? {
        option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier
    }

    /// Dumps the raw media-selection options so a device run reveals exactly
    /// what AVFoundation exposed for this stream (counts, names, language tags,
    /// forced flags) — the ground truth behind "audio shows unknown / subtitle
    /// missing" reports. Names here are not sensitive (e.g. "Unknown"/"English").
    private func logTrackDiagnostics(
        audible: AVMediaSelectionGroup?,
        legible: AVMediaSelectionGroup?,
        audio: [AudioTrack],
        subtitles: [SubtitleTrack]
    ) {
        func describe(_ group: AVMediaSelectionGroup?) -> String {
            guard let group else { return "nil" }
            if group.options.isEmpty { return "empty" }
            return group.options.enumerated().map { index, opt in
                let lang = opt.extendedLanguageTag ?? "—"
                let forced = opt.hasMediaCharacteristic(.containsOnlyForcedSubtitles) ? " forced" : ""
                return "[\(index) '\(opt.displayName)' lang=\(lang) type=\(opt.mediaType.rawValue)\(forced)]"
            }.joined(separator: " ")
        }
        let serverStreams = mediaStreams
            .filter { $0.kind == .audio || $0.kind == .subtitle }
            .map { "[\($0.index) \($0.kind.rawValue) '\($0.displayTitle ?? "—")' lang=\($0.language ?? "—")\($0.isExternal ? " ext" : "")]" }
            .joined(separator: " ")
        Log.playback.info(
            """
            AVKit tracks: audible=\(audible?.options.count ?? -1, privacy: .public) \
            legible=\(legible?.options.count ?? -1, privacy: .public) \
            → audio=\(audio.count, privacy: .public) subs=\(subtitles.count, privacy: .public) | \
            audible: \(describe(audible), privacy: .public) | \
            legible: \(describe(legible), privacy: .public) | \
            server[defA=\(self.defaultAudioStreamIndex ?? -1, privacy: .public) defS=\(self.defaultSubtitleStreamIndex ?? -1, privacy: .public)]: \
            \(serverStreams.isEmpty ? "none" : serverStreams, privacy: .public)
            """
        )
    }

    private func legibleGroup() async -> AVMediaSelectionGroup? {
        guard let asset = currentItem?.asset as? AVURLAsset else { return nil }
        return try? await asset.loadMediaSelectionGroup(for: .legible)
    }

    private func select(trackID: TrackID, characteristic: AVMediaCharacteristic) async {
        // This engine only ever vends `.avKitOption` ids; any other namespace
        // (a Jellyfin stream index from the transcode path) is not ours to honor.
        guard
            let index = trackID.avKitOptionIndex,
            let asset = currentItem?.asset as? AVURLAsset,
            let group = try? await asset.loadMediaSelectionGroup(for: characteristic),
            group.options.indices.contains(index)
        else { return }
        currentItem?.select(group.options[index], in: group)
    }
}

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
        supportsAudioAirPlay: true,
        supportsNowPlayingIntegration: true
    )

    public nonisolated let state: AsyncStream<PlaybackState>
    private nonisolated let continuation: AsyncStream<PlaybackState>.Continuation

    private let player = AVPlayer()
    public nonisolated var avPlayer: AVPlayer { player }

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
    /// Loads the media-selection inventory off the actor. Held so `teardown()`
    /// can cancel it — otherwise a slow `loadMediaSelectionGroup` keeps the
    /// AVPlayerItem (and its open network connection) alive after dismissal.
    private var inventoryTask: Task<Void, Never>?

    // Server-side track metadata for the current asset, used to label tracks a
    // transcode manifest left unnamed.
    private var mediaStreams: [MediaStreamInfo] = []
    private var defaultAudioStreamIndex: Int?
    private var defaultSubtitleStreamIndex: Int?

    public init(tuning: StartupTuning = .systemDefault) {
        self.tuning = tuning
        // Bounded so a wedged consumer can't grow the buffer without limit.
        // `.bufferingNewest` keeps the freshest beats — the latest position plus any
        // terminal .ready/.ended/.failed (nothing follows those, so they're never the
        // dropped-oldest) — and 32 ≈ 16s of 0.5s position beats, far beyond what the
        // MainActor consumer ever queues. It only sheds stale intermediate positions
        // under a real stall, which the next beat supersedes anyway.
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.state = stream
        self.continuation = continuation
        super.init()
        continuation.yield(.idle)
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
            continuation.yield(.buffering(position: position, duration: item.duration, buffered: buffered))
        case .playing:
            continuation.yield(.playing(position: position, duration: item.duration, buffered: buffered))
        case .paused:
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
            item.seek(to: start, completionHandler: nil)
        }
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
    private func handleLoadTimeout() {
        guard currentItem != nil else { return }
        continuation.yield(.failed(.assetNotPlayable))
    }

    public func pause() async {
        player.pause()
        if let item = currentItem, item.status == .readyToPlay {
            let position = player.currentTime()
            continuation.yield(.paused(
                position: position,
                duration: item.duration,
                buffered: Self.bufferedEnd(of: item, at: position)
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

    public func seek(to time: CMTime) async {
        // A seek OUTSIDE the buffered range is a real media fetch, but a PAUSED
        // player performs it without ever entering .waitingToPlayAtSpecifiedRate
        // — and the drag-scrub flow always pauses before seeking, so on a
        // transcode the whole multi-second fetch would otherwise read as a dead
        // paused frame (no stall beat, no scrim). Emit the fetch explicitly.
        if let item = currentItem, item.status == .readyToPlay,
           Self.bufferedEnd(of: item, at: time) == nil {
            continuation.yield(.buffering(position: time, duration: item.duration, buffered: nil))
        }
        // Default (efficient) tolerance, not zero. Frame-exact seeking on an HLS
        // transcode is pathologically slow and can stall — it made scrubbing a 4K
        // stream feel stuck. Segment-level accuracy is right for both scrubbing and
        // the resume seek: Jellyfin's transcode is a full-timeline playlist, so
        // resume is an ordinary seek — the stream URL carries no start offset.
        #if DEBUG
        let preSeek = player.currentTime()
        #endif
        let finished = await player.seek(to: time)
        #if DEBUG
        // DIAGNOSTIC (temporary, dev-only) — "subtitles drift after scrubbing": a
        // transcode seek can leave `currentTime` (the HLS playlist clock the
        // client-rendered cue overlay matches against) ahead of the decoded frames, so
        // the absolute `copyTimestamps` cues fire early. The client has no independent
        // clock to catch it, so this line is the witness. `date` is the playlist's
        // EXT-X-PROGRAM-DATE-TIME mapping (nil if Jellyfin emits none); if present it's a
        // true source-time anchor the overlay could match against instead of
        // `currentTime`. Compare `target` vs `landed` and watch whether `seekable`
        // re-bases across the scrub that desyncs. `#if DEBUG` so it never ships as
        // per-seek log I/O on the scrub hot path.
        let landed = player.currentTime()
        func secs(_ t: CMTime) -> String {
            let s = CMTimeGetSeconds(t)
            return s.isFinite ? String(format: "%.2f", s) : "—"
        }
        let seekable = player.currentItem?.seekableTimeRanges.first?.timeRangeValue
        let seekableDesc = seekable.map { "\(secs($0.start))…\(secs(CMTimeRangeGetEnd($0)))" } ?? "nil"
        let dateDesc = player.currentItem?.currentDate().map { "\($0)" } ?? "nil"
        Log.playback.info(
            "seek target=\(secs(time), privacy: .public) pre=\(secs(preSeek), privacy: .public) landed=\(secs(landed), privacy: .public) finished=\(finished, privacy: .public) seekable=\(seekableDesc, privacy: .public) date=\(dateDesc, privacy: .public)"
        )
        #endif
        // A superseded seek must NOT land its post-seek beat. When a newer seek
        // arrives, AVPlayer resumes THIS call with finished == false — but only
        // AFTER the newer call already pre-emitted its .buffering, so the stale
        // .paused beat below would wipe the stall and present a bare paused UI
        // while the new fetch is still in flight (device-found: drag → buffering
        // → re-drag before the scrim closed showed paused, no scrim). The newest
        // seek owns every subsequent beat.
        guard finished else { return }
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
                buffered: Self.bufferedEnd(of: item, at: position)
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
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) async {
        guard let group = await legibleGroup() else { return }
        guard let track else {
            currentItem?.select(nil, in: group)
            return
        }
        await select(trackID: track.id, characteristic: .legible)
    }

    public func teardown() async {
        detachCurrentItem()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        mediaStreams = []
        defaultAudioStreamIndex = nil
        defaultSubtitleStreamIndex = nil
        continuation.finish()
    }

    /// Tears down the current item's observers + async inventory load. Shared by
    /// `teardown()` (full stop) and `load()` (reload-safe: a track switch installs a
    /// new item on the same player). Deliberately does NOT finish the state stream or
    /// drop the AVPlayer, so a reload keeps the surface — and the layer — alive.
    private func detachCurrentItem() {
        loadWatchdog.disarm()   // teardown or reload — cancel the deadline (play() re-arms on reload)
        inventoryTask?.cancel()
        inventoryTask = nil
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

        // The engine's TRUE selection — what's actually audible/legible right now,
        // which is what answers "I picked a subtitle but nothing renders".
        if let asset = item.asset as? AVURLAsset {
            let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
            let selection = item.currentMediaSelection
            info.audibleOptions = audibleGroup?.options.map(\.displayName) ?? []
            info.legibleOptions = legibleGroup?.options.map(\.displayName) ?? []
            info.selectedAudible = audibleGroup.flatMap { selection.selectedMediaOption(in: $0)?.displayName }
            info.selectedLegible = legibleGroup.flatMap { selection.selectedMediaOption(in: $0)?.displayName }
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
            continuation.yield(.failed(.assetNotPlayable))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleEnded() {
        loadWatchdog.disarm()
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
            continuation.yield(.paused(position: time, duration: item.duration, buffered: buffered))
        case .waitingToPlayAtSpecifiedRate:
            continuation.yield(.buffering(position: time, duration: item.duration, buffered: buffered))
        case .playing:
            continuation.yield(.playing(position: time, duration: item.duration, buffered: buffered))
        @unknown default:
            continuation.yield(.playing(position: time, duration: item.duration, buffered: buffered))
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
        if let waits = tuning.automaticallyWaitsToMinimizeStalling {
            player.automaticallyWaitsToMinimizeStalling = waits
        }
    }

    /// Trailing path of an HLS resource URI with the query dropped (the query
    /// is where the api_key lives): "main/123.mp4". Enough to tell playlist vs
    /// init vs media segment apart without leaking credentials.
    private static func redactedTail(of uri: String) -> String? {
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

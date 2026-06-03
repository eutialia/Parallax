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
    /// Parsed cues for a client-rendered subtitle (transcode path): the
    /// correctly-timed sidecar WebVTT that `SubtitleOverlayView` draws. Empty
    /// when no text subtitle is active, or on direct-play where the engine
    /// renders subtitles itself. This is how we sidestep the in-manifest WebVTT
    /// drift (jellyfin/jellyfin#16647).
    private(set) var activeSubtitleCues: [SubtitleCue] = []
    private(set) var currentPosition: CMTime = .zero
    private(set) var currentDuration: CMTime = .zero
    /// Whether the engine is actively playing (vs paused). `phase` stays `.playing`
    /// while paused (the video surface stays on screen), so the play/pause button
    /// must read this — not `phase` — or it shows "pause" forever and can never resume.
    private(set) var isPlaying: Bool = false

    // MARK: - Player chrome (P4)

    /// The playing item's title — surfaced in the player's top bar.
    var title: String { itemTitle }

    /// Caption for the liquid-orb loader. A transcode audio switch reloads the
    /// stream ("Switching audio · <track>"); a first play / re-buffer is "Loading".
    var loaderTitle: String { isSwitchingTracks ? "Switching audio" : "Loading" }
    var loaderSubtitle: String? { isSwitchingTracks ? selectedAudioTrack?.displayName : nil }

    /// User-selected playback speed (1.0 = normal). Drives the speed chip.
    private(set) var playbackRate: Float = 1

    /// A concise format summary for the top bar, e.g. "4K · Dolby Vision · 7.1".
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
        if let channels = audio?.channels { parts.append(Self.channelLayout(channels)) }
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

    /// Seek to a chapter's start. Reconstruct the full sub-second offset (the
    /// fractional part lives in `attoseconds`) — `.seconds` alone would land a
    /// chapter with a fractional start up to ~1s early, inside the prior chapter.
    func seekToChapter(_ chapter: Chapter) async {
        let c = chapter.start.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        await engine?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
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

    private var stateTask: Task<Void, Never>?
    private var subtitleFetchTask: Task<Void, Never>?
    private var resolved: ResolvedPlayback?
    private var didReportStart = false
    private var didReportStopped = false
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
        subtitleFetch: @escaping @Sendable (URL) async -> Data? = { try? await URLSession.shared.data(from: $0).0 }
    ) {
        self.deviceProfileBuilder = deviceProfileBuilder
        self.playbackInfo = playbackInfo
        self.resolve = resolve
        self.engineFactory = engineFactory
        self.audioSession = audioSession
        self.fetchDetail = fetchDetail
        self.subtitleFetch = subtitleFetch
    }

    isolated deinit {
        // Match the JellyfinSearchViewModel teardown discipline: the consumer
        // Task is stored on the VM, so cancel it on the MainActor before
        // release. The engine's stream finishes on teardown() (called from
        // stop()); cancelling here makes teardown immediate if stop() was
        // never reached.
        stateTask?.cancel()
        subtitleFetchTask?.cancel()
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
            await start(item: detail)
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            Log.playback.error("item detail fetch failed: \(error.networkDiagnostic, privacy: .public)")
            phase = .failed(.unexpected("couldn't load item", underlying: AnySendableError(error)))
        }
    }

    func start(item: ItemDetail) async {
        phase = .loading
        playingItem = item
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

        do {
            do {
                try await audioSession.activate()
            } catch {
                // An audio-session config failure is not a connectivity problem;
                // map it to a distinct case and log the real error so on-device
                // failures leave a trail (the bare AVAudioSession NSError is not
                // an AppError, so it would otherwise fall into the generic catch
                // and be mislabeled as "Couldn't reach the file").
                Log.playback.error("audio session activate failed: \(error.networkDiagnostic, privacy: .public)")
                throw AppError.playback(.audioSessionFailed)
            }
            let resumeTime = ResumePolicy.resumeStartTime(positionTicks: positionTicks, runtime: runtime)
            try await beginPlayback(
                item: item,
                startTime: resumeTime,
                audioStreamIndex: nil,
                subtitleStreamIndex: nil
            )
        } catch let error as AppError {
            phase = .failed(error)
            await audioSession.deactivate()
        } catch {
            // A non-AppError reaching here is genuinely unexpected (resolve()
            // already maps its failures to AppError). Log it and preserve the
            // underlying error in diagnostics instead of mislabeling it as a
            // network problem.
            Log.playback.error("playback start failed (unmapped): \(error.networkDiagnostic, privacy: .public)")
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
        let caps = await deviceProfileBuilder.build()
        let resolved = try await resolve(item.id, caps, startTime, audioStreamIndex, subtitleStreamIndex)
        self.resolved = resolved
        currentAudioStreamIndex = audioStreamIndex ?? resolved.defaultAudioStreamIndex
        // Subtitle is the user's EXPLICIT choice only — never seeded from the server
        // default. That isolates it from audio switching (an audio switch carries
        // this value unchanged: none stays none, a chosen sub stays chosen) and means
        // nothing is auto-burned-in. nil = "no subtitle". Burn-in is a later phase.
        currentSubtitleStreamIndex = subtitleStreamIndex
        if resolved.method == .transcode {
            populateTranscodeMenus(from: resolved)
        }
        recomputeMediaSummary()

        let asset = Self.makeAsset(from: resolved)
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
        } catch {
            // A load failure must not leave the engine + its state subscription
            // dangling: tear down before propagating, so start()/switchTranscodeTrack
            // surface .failed with no leaked Task and no open AsyncStream.
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
    /// the reference. The focused engine-only teardown (no session report, no UI
    /// reset) used by a load failure and a failed track switch.
    private func tearDownEngine() async {
        stateTask?.cancel()
        stateTask = nil
        if let engine {
            await engine.teardown()
            self.engine = nil
        }
    }

    func stop() async {
        stateTask?.cancel()
        stateTask = nil
        if let engine {
            await engine.teardown()
        }
        nowPlaying.clear()
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
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        activeSubtitleCues = []
        currentPosition = .zero
        currentDuration = .zero
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

    func retry() async {
        let item = playingItem
        let id = pendingItemID
        await stop()
        phase = .idle
        didReportStart = false
        didReportStopped = false
        lastPosition = .zero
        if let item { await start(item: item) }
        else if let id { await start(itemID: id) }
        else { Log.playback.error("retry() had no item or id to replay") }
    }

    func selectAudioTrack(_ track: AudioTrack) async {
        // Direct-play has every track in the stream → switch in-engine (instant).
        // Transcode carries only the baked-in rendition → re-resolve around the
        // chosen source index (track.id) and reload at the current position.
        if resolved?.method == .transcode {
            // Transcode menus carry `.jellyfinStream` ids — the source stream index
            // the server selects by. A non-jellyfin id here would be a wiring bug.
            guard let index = track.id.jellyfinStreamIndex else { return }
            selectedAudioTrack = track
            await switchTranscodeTrack(audioStreamIndex: index, subtitleStreamIndex: currentSubtitleStreamIndex)
        } else {
            guard let engine else { return }
            await engine.setAudioTrack(track)
            selectedAudioTrack = track
        }
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) async {
        if resolved?.method == .transcode {
            // Client-side rendering: the chosen text subtitle is fetched as a
            // correctly-timed sidecar VTT and drawn by SubtitleOverlayView — NO
            // server re-transcode, so toggling subtitles is instant and immune to
            // the in-manifest WebVTT drift. (Image subs never reach here; they're
            // filtered out of the transcode menu — burn-in is a later phase.)
            selectedSubtitleTrack = track
            if let index = track?.id.jellyfinStreamIndex {
                currentSubtitleStreamIndex = index
                loadSidecarSubtitle(streamIndex: index)
            } else {
                currentSubtitleStreamIndex = -1   // Jellyfin's "no subtitle" sentinel
                clearSidecarSubtitle()
            }
        } else {
            guard let engine else { return }
            await engine.setSubtitleTrack(track)
            selectedSubtitleTrack = track
        }
    }

    /// Fetches + parses the sidecar WebVTT for `streamIndex` into
    /// `activeSubtitleCues`. Cancels any in-flight fetch first so a slow/stale
    /// parse can't land on screen after a newer pick.
    private func loadSidecarSubtitle(streamIndex: Int) {
        subtitleFetchTask?.cancel()
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
    }

    /// Rebuilds the transcode around new stream indices, resuming at the current
    /// position. Costs a brief re-buffer — the server has to re-encode around the
    /// chosen track. The engine instance is REUSED (reloaded), so the video surface
    /// stays mounted and holds the last frame through the swap instead of blinking to
    /// black; the audio session stays active too.
    private func switchTranscodeTrack(audioStreamIndex: Int?, subtitleStreamIndex: Int?) async {
        guard let item = playingItem else { return }
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
        // Close the outgoing transcode session so the server doesn't leak it,
        // then reset BOTH reporting flags — the reload is a brand-new play session
        // that must reportStart and reportStopped on its own terms.
        await reportStoppedIfNeeded()
        didReportStart = false
        didReportStopped = false

        do {
            try await beginPlayback(
                item: item,
                startTime: resumePosition,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                reusingEngine: true
            )
        } catch let error as AppError {
            phase = .failed(error)
            // resolve threw before the reused engine reloaded → the stale stream is
            // still mounted; tear it down so it doesn't play on under the error UI,
            // and release the audio session like start()'s failure paths do.
            await tearDownEngine()
            await audioSession.deactivate()
        } catch {
            Log.playback.error("track switch failed: \(error.networkDiagnostic, privacy: .public)")
            phase = .failed(.unexpected("track switch failed", underlying: AnySendableError(error)))
            await tearDownEngine()
            await audioSession.deactivate()
        }
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
                availableSubtitleTracks = tracks.subtitles
                // Reflect the engine's default selection so the menus show a
                // checkmark on the track that's actually playing. Don't clobber
                // a choice the user already made (a late/duplicate .ready).
                if selectedAudioTrack == nil {
                    selectedAudioTrack = tracks.audio.first { $0.id == tracks.selectedAudioID }
                }
                if selectedSubtitleTrack == nil {
                    selectedSubtitleTrack = tracks.subtitles.first { $0.id == tracks.selectedSubtitleID }
                }
            }
        case .playing(let position, let duration):
            phase = .playing
            isPlaying = true
            lastPosition = position
            currentPosition = position
            currentDuration = duration
            nowPlaying.update(position: position, duration: duration, isPlaying: true, title: itemTitle)
            if !didReportStart {
                didReportStart = true
                await playbackInfo.reportStart(beat(position: position, isPaused: false, from: resolved))
            } else {
                await playbackInfo.reportProgress(beat(position: position, isPaused: false, from: resolved))
            }
        case .paused(let position, let duration):
            isPlaying = false
            lastPosition = position
            currentPosition = position
            currentDuration = duration
            nowPlaying.update(position: position, duration: duration, isPlaying: false, title: itemTitle)
            await playbackInfo.reportProgress(beat(position: position, isPaused: true, from: resolved))
        case .ended:
            isPlaying = false
            await reportStoppedIfNeeded()
        case .failed(let error):
            isPlaying = false
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
                    codecLabel: Self.audioCodecLabel(stream),
                    isTranscode: isTranscode,
                    transcodeTarget: isTranscode
                        ? "AAC · \(Self.channelLayout(min(stream.channels ?? 2, 8)))"
                        : nil
                )
            }
        availableSubtitleTracks = resolved.mediaStreams
            .filter { $0.kind == .subtitle && !$0.isImageSubtitle }
            .map { stream in
                SubtitleTrack(
                    id: .jellyfinStream(stream.index),
                    displayName: stream.menuLabel,
                    languageCode: stream.language,
                    isForced: stream.isForced,
                    sourceLabel: stream.isExternal ? "External" : "Embedded",
                    formatLabel: stream.codec?.uppercased(),
                    isSDH: stream.isHearingImpaired
                )
            }

        selectedAudioTrack = availableAudioTracks.first { $0.id == currentAudioStreamIndex.map(TrackID.jellyfinStream) }
        selectedSubtitleTrack = availableSubtitleTracks.first { $0.id == currentSubtitleStreamIndex.map(TrackID.jellyfinStream) }
    }

    /// Source codec + channel layout, e.g. "TRUEHD · 7.1" — the SECONDARY detail
    /// line under the track's name. Nil when neither is known.
    private static func audioCodecLabel(_ stream: MediaStreamInfo) -> String? {
        let parts = [stream.codec?.uppercased(), stream.channels.map { channelLayout($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Resolution bucket. Delegates the 1080p+ tiers to the shared `QualityBadge`
    /// (single source with the poster badges), keeping the player-only sub-1080p
    /// fallback the grid intentionally omits.
    private static func qualityLabel(width: Int?, height: Int?) -> String? {
        if let badge = QualityBadge.resolution(width: width, height: height) { return badge }
        let h = height ?? 0, w = width ?? 0
        if h >= 700 || w >= 1200 { return "720p" }
        if h > 0 { return "\(h)p" }
        return nil
    }

    /// HDR label — delegated to the shared `QualityBadge.hdr` (single source with the
    /// poster badges; also gets the DOVIInvalid exclusion for free).
    private static func hdrLabel(_ range: String?) -> String? {
        QualityBadge.hdr(range)
    }

    /// Channel count → layout label. Shared by the summary and the transcode menu.
    static func channelLayout(_ channels: Int?) -> String {
        switch channels ?? 2 {
        case ...1: return "Mono"
        case 2:    return "Stereo"
        case 3:    return "2.1"
        case 6:    return "5.1"
        case 7:    return "6.1"
        case 8:    return "7.1"
        default:   return "\(channels ?? 2)ch"
        }
    }

    private static func makeAsset(from resolved: ResolvedPlayback) -> PlayableAsset {
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
            externalSubtitles: [],
            // Authoritative track names/languages — the engine uses these to
            // label tracks a transcode manifest left unnamed.
            mediaStreams: resolved.mediaStreams,
            defaultAudioStreamIndex: resolved.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: resolved.defaultSubtitleStreamIndex
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

    /// Live subtitle-delay nudge (VLC retimes; AVKit ignores). `ms` is absolute.
    func setSubtitleDelay(ms: Int) async {
        await engine?.setSubtitleDelay(milliseconds: ms)
    }
}
#endif

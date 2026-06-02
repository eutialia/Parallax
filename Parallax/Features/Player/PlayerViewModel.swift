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

    private let deviceProfileBuilder: DeviceProfileBuilder
    private let playbackInfo: any PlaybackReporting
    private let resolve: ResolveCall
    private let engineFactory: @Sendable (PlaybackEngineID) -> any PlaybackEngine
    private let audioSession: any AudioSessionControlling
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
    private var isSwitchingTracks = false
    private var lastPosition: CMTime = .zero
    private let nowPlaying = NowPlayingController()
    private var itemTitle: String = ""

    // Transcode track switching: the server bakes one audio + only text subs
    // into a transcode, so switching tracks means re-resolving the stream around
    // a different source index. We keep the item + the current indices to rebuild.
    private var playingItem: ItemDetail?
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
        engineFactory: @escaping @Sendable (PlaybackEngineID) -> any PlaybackEngine,
        audioSession: any AudioSessionControlling,
        subtitleFetch: @escaping @Sendable (URL) async -> Data? = { try? await URLSession.shared.data(from: $0).0 }
    ) {
        self.deviceProfileBuilder = deviceProfileBuilder
        self.playbackInfo = playbackInfo
        self.resolve = resolve
        self.engineFactory = engineFactory
        self.audioSession = audioSession
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

    func retry(item: ItemDetail) async {
        await stop()
        phase = .idle
        didReportStart = false
        didReportStopped = false
        lastPosition = .zero
        await start(item: item)
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
            .map { AudioTrack(id: .jellyfinStream($0.index), displayName: Self.transcodeAudioLabel(for: $0), languageCode: $0.language) }
        availableSubtitleTracks = resolved.mediaStreams
            .filter { $0.kind == .subtitle && !$0.isImageSubtitle }
            .map { SubtitleTrack(id: .jellyfinStream($0.index), displayName: $0.menuLabel, languageCode: $0.language, isForced: $0.isForced) }

        selectedAudioTrack = availableAudioTracks.first { $0.id == currentAudioStreamIndex.map(TrackID.jellyfinStream) }
        selectedSubtitleTrack = availableSubtitleTracks.first { $0.id == currentSubtitleStreamIndex.map(TrackID.jellyfinStream) }
    }

    /// Rough delivered-format label for the transcode audio menu. The track's
    /// `menuLabel` names the SOURCE mix (e.g. "English - TrueHD 7.1"), but on the
    /// HLS transcode/remux the server only stream-COPIES audio whose codec is in
    /// the device profile's transcode set (aac/ac3/eac3) — that arrives untouched,
    /// channels and any DD+ Atmos intact, so the source label is already honest.
    /// Anything else (TrueHD, DTS-HD, FLAC…) is re-encoded to AAC capped at 7.1, so
    /// we annotate the delivered format and the menu doesn't promise a lossless /
    /// Atmos track we can't actually deliver. Placeholder presentation baked into
    /// the label — slated for a proper redesign.
    private static func transcodeAudioLabel(for stream: MediaStreamInfo) -> String {
        let copyCodecs: Set<String> = ["aac", "ac3", "eac3"]
        if copyCodecs.contains((stream.codec ?? "").lowercased()) {
            return stream.menuLabel
        }
        let channels = min(stream.channels ?? 2, 8)   // we never request more than 7.1
        let layout: String
        switch channels {
        case ...1: layout = "Mono"
        case 2:    layout = "Stereo"
        case 6:    layout = "5.1"
        case 8:    layout = "7.1"
        default:   layout = "\(channels)ch"
        }
        return "\(stream.menuLabel) → AAC \(layout)"
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

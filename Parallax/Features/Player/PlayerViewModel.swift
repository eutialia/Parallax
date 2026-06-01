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

    private var stateTask: Task<Void, Never>?
    private var resolved: ResolvedPlayback?
    private var didReportStart = false
    private var didReportStopped = false
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
        audioSession: any AudioSessionControlling
    ) {
        self.deviceProfileBuilder = deviceProfileBuilder
        self.playbackInfo = playbackInfo
        self.resolve = resolve
        self.engineFactory = engineFactory
        self.audioSession = audioSession
    }

    isolated deinit {
        // Match the JellyfinSearchViewModel teardown discipline: the consumer
        // Task is stored on the VM, so cancel it on the MainActor before
        // release. The engine's stream finishes on teardown() (called from
        // stop()); cancelling here makes teardown immediate if stop() was
        // never reached.
        stateTask?.cancel()
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
        subtitleStreamIndex: Int?
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

        let engine = engineFactory(id)
        self.engine = engine
        subscribe(to: engine)
        nowPlaying.configure(
            onSeek: { [weak self] time in Task { await self?.engine?.seek(to: time) } },
            onPlay: { [weak self] in Task { await self?.engine?.play() } },
            onPause: { [weak self] in Task { await self?.engine?.pause() } }
        )

        do {
            try await engine.load(asset)
        } catch {
            // A load failure must not leave the engine + its state subscription
            // dangling: tear down before propagating, so start()/switchTranscodeTrack
            // surface .failed with no leaked Task and no open AsyncStream.
            stateTask?.cancel()
            stateTask = nil
            await engine.teardown()
            self.engine = nil
            throw error
        }
        await engine.play()
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
            selectedSubtitleTrack = track
            // -1 is Jellyfin's "no subtitle" sentinel; nil would mean "server default".
            let subtitleIndex = track.flatMap { $0.id.jellyfinStreamIndex } ?? -1
            await switchTranscodeTrack(audioStreamIndex: currentAudioStreamIndex, subtitleStreamIndex: subtitleIndex)
        } else {
            guard let engine else { return }
            await engine.setSubtitleTrack(track)
            selectedSubtitleTrack = track
        }
    }

    /// Rebuilds the transcode around new stream indices, resuming at the current
    /// position. Costs a brief re-buffer — the server has to re-encode around the
    /// chosen track (a PGS subtitle, for instance, is burned in). The audio
    /// session stays active; only the engine + stream are replaced.
    private func switchTranscodeTrack(audioStreamIndex: Int?, subtitleStreamIndex: Int?) async {
        guard let item = playingItem else { return }
        // currentPosition is relative to the *current* transcode (which began at
        // its own origin); the new request needs the absolute source position.
        let origin = resolved?.startTime ?? .zero
        let absolutePosition = CMTimeAdd(origin, currentPosition)

        phase = .loading
        // Close the outgoing transcode session so the server doesn't leak it,
        // then reset BOTH reporting flags — the re-resolve is a brand-new play
        // session that must reportStart and reportStopped on its own terms (the
        // old session already reported stopped just above).
        await reportStoppedIfNeeded()
        stateTask?.cancel()
        stateTask = nil
        if let engine {
            await engine.teardown()
        }
        engine = nil
        didReportStart = false
        didReportStopped = false

        do {
            try await beginPlayback(
                item: item,
                startTime: absolutePosition,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex
            )
        } catch let error as AppError {
            phase = .failed(error)
            // The switch tore the engine down and ended in a terminal .failed
            // state — release the audio session like start()'s failure paths do,
            // rather than holding audio focus until the user dismisses.
            await audioSession.deactivate()
        } catch {
            Log.playback.error("track switch failed: \(error.networkDiagnostic, privacy: .public)")
            phase = .failed(.unexpected("track switch failed", underlying: AnySendableError(error)))
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
            .map { AudioTrack(id: .jellyfinStream($0.index), displayName: $0.menuLabel, languageCode: $0.language) }
        availableSubtitleTracks = resolved.mediaStreams
            .filter { $0.kind == .subtitle && !$0.isImageSubtitle }
            .map { SubtitleTrack(id: .jellyfinStream($0.index), displayName: $0.menuLabel, languageCode: $0.language, isForced: $0.isForced) }

        selectedAudioTrack = availableAudioTracks.first { $0.id == currentAudioStreamIndex.map(TrackID.jellyfinStream) }
        selectedSubtitleTrack = availableSubtitleTracks.first { $0.id == currentSubtitleStreamIndex.map(TrackID.jellyfinStream) }
    }

    private static func makeAsset(from resolved: ResolvedPlayback) -> PlayableAsset {
        PlayableAsset(
            url: resolved.url,
            headers: nil,
            hints: deliveredHints(for: resolved),
            // Direct-play/-stream seek on .ready; transcode bakes the offset
            // into the stream URL, so only honor startTime here for non-transcode.
            startTime: resolved.method == .transcode ? nil : resolved.startTime,
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

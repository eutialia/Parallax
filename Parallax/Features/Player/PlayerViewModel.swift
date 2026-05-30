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
    private(set) var availableAudioTracks: [AudioTrack] = []
    private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    private(set) var selectedAudioTrack: AudioTrack? = nil
    private(set) var selectedSubtitleTrack: SubtitleTrack? = nil
    private(set) var currentPosition: CMTime = .zero
    private(set) var currentDuration: CMTime = .zero

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

    /// The resolve surface, narrowed so the integration test can inject a stub
    /// without standing up a full PlaybackInfoService. Mirrors 4c's
    /// PlaybackInfoService.resolve(item:capabilities:startTime:) exactly.
    typealias ResolveCall = @Sendable (ItemID, DeviceCapabilities, CMTime?) async throws -> ResolvedPlayback

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
        let itemID = item.id
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
            let caps = await deviceProfileBuilder.build()
            let resumeTime = ResumePolicy.resumeStartTime(positionTicks: positionTicks, runtime: runtime)
            let resolved = try await resolve(itemID, caps, resumeTime)
            self.resolved = resolved

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

            try await engine.load(asset)
            await engine.play()
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

    func stop() async {
        stateTask?.cancel()
        stateTask = nil
        if let engine {
            await engine.teardown()
        }
        nowPlaying.clear()
        if let resolved, !didReportStopped {
            didReportStopped = true
            await playbackInfo.reportStopped(beat(position: lastPosition, isPaused: true, from: resolved))
        }
        await audioSession.deactivate()
        engine = nil
        availableAudioTracks = []
        availableSubtitleTracks = []
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        currentPosition = .zero
        currentDuration = .zero
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
        guard let engine else { return }
        await engine.setAudioTrack(track)
        selectedAudioTrack = track
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) async {
        guard let engine else { return }
        await engine.setSubtitleTrack(track)
        selectedSubtitleTrack = track
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
            availableAudioTracks = tracks.audio
            availableSubtitleTracks = tracks.subtitles
            phase = .loading
        case .playing(let position, let duration):
            phase = .playing
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
            lastPosition = position
            currentPosition = position
            currentDuration = duration
            nowPlaying.update(position: position, duration: duration, isPlaying: false, title: itemTitle)
            await playbackInfo.reportProgress(beat(position: position, isPaused: true, from: resolved))
        case .ended:
            if !didReportStopped {
                didReportStopped = true
                await playbackInfo.reportStopped(beat(position: lastPosition, isPaused: true, from: resolved))
            }
        case .failed(let error):
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

    private static func makeAsset(from resolved: ResolvedPlayback) -> PlayableAsset {
        PlayableAsset(
            url: resolved.url,
            headers: nil,
            hints: deliveredHints(for: resolved),
            // Direct-play/-stream seek on .ready; transcode bakes the offset
            // into the stream URL, so only honor startTime here for non-transcode.
            startTime: resolved.method == .transcode ? nil : resolved.startTime,
            externalSubtitles: []
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

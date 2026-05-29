import Foundation
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
        case .episode(let d):
            positionTicks = d.episode.userData.playbackPositionTicks
            runtime = d.episode.runtime
        case .series, .season:
            phase = .failed(.playback(.unsupportedFormat))
            return
        }

        do {
            try await audioSession.activate()
            let caps = await deviceProfileBuilder.build()
            let resumeTime = ResumePolicy.resumeStartTime(positionTicks: positionTicks, runtime: runtime)
            let resolved = try await resolve(itemID, caps, resumeTime)
            self.resolved = resolved

            let asset = Self.makeAsset(from: resolved)
            let id = EngineSelector.select(hints: asset.hints)
            guard id == .avKit else {
                // .vlcKit is not shippable until Phase 5 — surface before the
                // engine factory is reached.
                phase = .failed(.playback(.unsupportedFormat))
                await audioSession.deactivate()
                return
            }

            let engine = engineFactory(id)
            self.engine = engine
            subscribe(to: engine)

            try await engine.load(asset)
            await engine.play()
        } catch let error as AppError {
            phase = .failed(error)
            await audioSession.deactivate()
        } catch {
            phase = .failed(.playback(.resourceUnavailable))
            await audioSession.deactivate()
        }
    }

    func stop() async {
        stateTask?.cancel()
        stateTask = nil
        if let engine {
            await engine.teardown()
        }
        if let resolved, !didReportStopped {
            didReportStopped = true
            await playbackInfo.reportStopped(beat(position: lastPosition, isPaused: true, from: resolved))
        }
        await audioSession.deactivate()
        engine = nil
    }

    func retry(item: ItemDetail) async {
        await stop()
        phase = .idle
        didReportStart = false
        didReportStopped = false
        lastPosition = .zero
        await start(item: item)
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
        case .ready:
            phase = .loading
        case .playing(let position, _):
            phase = .playing
            lastPosition = position
            if !didReportStart {
                didReportStart = true
                await playbackInfo.reportStart(beat(position: position, isPaused: false, from: resolved))
            } else {
                await playbackInfo.reportProgress(beat(position: position, isPaused: false, from: resolved))
            }
        case .paused(let position, _):
            lastPosition = position
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
            hints: PlaybackHints(
                scheme: resolved.url.scheme,
                container: resolved.container,
                videoCodec: resolved.videoCodec,
                audioCodec: resolved.audioCodec,
                subtitleFormats: []
            ),
            // Direct-play/-stream seek on .ready; transcode bakes the offset
            // into the stream URL, so only honor startTime here for non-transcode.
            startTime: resolved.method == .transcode ? nil : resolved.startTime,
            externalSubtitles: []
        )
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

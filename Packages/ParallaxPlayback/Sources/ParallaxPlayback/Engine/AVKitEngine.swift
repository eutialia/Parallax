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

    private var currentItem: AVPlayerItem?
    private var pendingStartTime: CMTime?
    private var statusObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    public override init() {
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream()
        self.state = stream
        self.continuation = continuation
        super.init()
        continuation.yield(.idle)
    }

    public func load(_ asset: PlayableAsset) async throws {
        continuation.yield(.loading)
        pendingStartTime = asset.startTime

        let urlAsset = AVURLAsset(url: asset.url)
        let item = AVPlayerItem(asset: urlAsset)
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
    }

    public func play() async { player.play() }

    public func pause() async {
        player.pause()
        if let item = currentItem, item.status == .readyToPlay {
            continuation.yield(.paused(position: player.currentTime(), duration: item.duration))
        }
    }

    public func seek(to time: CMTime) async {
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        continuation.finish()
    }

    // MARK: - Private

    private func handleStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            if let start = pendingStartTime {
                pendingStartTime = nil
                Task { await seek(to: start) }
            }
            continuation.yield(.ready(duration: item.duration, tracks: trackInventory(of: item)))
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
            continuation.yield(.failed(.assetNotPlayable))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleEnded() {
        continuation.yield(.ended)
    }

    private func emitTimeUpdate(at time: CMTime) {
        guard let item = currentItem, item.status == .readyToPlay else { return }
        if player.timeControlStatus == .paused {
            continuation.yield(.paused(position: time, duration: item.duration))
        } else {
            continuation.yield(.playing(position: time, duration: item.duration))
        }
    }

    private func trackInventory(of item: AVPlayerItem) -> TrackInventory {
        var audio: [AudioTrack] = []
        var subtitles: [SubtitleTrack] = []

        guard let asset = item.asset as? AVURLAsset else {
            return TrackInventory.empty
        }

        if let audibleGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            for option in audibleGroup.options {
                let langCode = option.locale?.language.languageCode?.identifier
                audio.append(AudioTrack(
                    id: option.displayName,
                    displayName: option.displayName,
                    languageCode: langCode
                ))
            }
        }

        if let legibleGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            for option in legibleGroup.options
                where !option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
                let langCode = option.locale?.language.languageCode?.identifier
                subtitles.append(SubtitleTrack(
                    id: option.displayName,
                    displayName: option.displayName,
                    languageCode: langCode,
                    isForced: false
                ))
            }
        }

        return TrackInventory(audio: audio, subtitles: subtitles)
    }

    private func legibleGroup() async -> AVMediaSelectionGroup? {
        guard let asset = currentItem?.asset as? AVURLAsset else { return nil }
        return try? await asset.loadMediaSelectionGroup(for: .legible)
    }

    private func select(trackID: String, characteristic: AVMediaCharacteristic) async {
        guard
            let asset = currentItem?.asset as? AVURLAsset,
            let group = try? await asset.loadMediaSelectionGroup(for: characteristic)
        else { return }
        if let option = group.options.first(where: { $0.displayName == trackID }) {
            currentItem?.select(option, in: group)
        }
    }
}

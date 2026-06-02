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
    /// Loads the media-selection inventory off the actor. Held so `teardown()`
    /// can cancel it — otherwise a slow `loadMediaSelectionGroup` keeps the
    /// AVPlayerItem (and its open network connection) alive after dismissal.
    private var inventoryTask: Task<Void, Never>?

    // Server-side track metadata for the current asset, used to label tracks a
    // transcode manifest left unnamed.
    private var mediaStreams: [MediaStreamInfo] = []
    private var defaultAudioStreamIndex: Int?
    private var defaultSubtitleStreamIndex: Int?

    public override init() {
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream()
        self.state = stream
        self.continuation = continuation
        super.init()
        continuation.yield(.idle)
    }

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
        // Default (efficient) tolerance, not zero. Frame-exact seeking on an HLS
        // transcode is pathologically slow and can stall — it made scrubbing a 4K
        // stream feel stuck. Segment-level accuracy is right for both scrubbing and
        // the resume seek: Jellyfin's transcode is a full-timeline playlist, so
        // resume is an ordinary seek — the stream URL carries no start offset.
        await player.seek(to: time)
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
        }

        if let videoTrack = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }) {
            let fps = Double(videoTrack.currentVideoFrameRate)
            info.renderedFrameRate = fps > 0 ? fps : nil
        }

        if let range = item.loadedTimeRanges.last?.timeRangeValue {
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            let now = CMTimeGetSeconds(item.currentTime())
            if end.isFinite, now.isFinite { info.bufferedSeconds = max(0, end - now) }
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
            if let start = pendingStartTime {
                pendingStartTime = nil
                Task { await seek(to: start) }
            }
            // Media-selection groups load asynchronously: the synchronous
            // `mediaSelectionGroup(forMediaCharacteristic:)` accessor is
            // deprecated and returns nil/incomplete data before the property
            // loads — which dropped the subtitle list on device. Resolve the
            // inventory on the actor, then emit .ready; duration is ready now.
            let duration = item.duration
            inventoryTask = Task { [weak self] in
                guard let self else { return }
                let tracks = await self.loadTrackInventory(of: item)
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
                languageCode: lang
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
                isForced: false
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

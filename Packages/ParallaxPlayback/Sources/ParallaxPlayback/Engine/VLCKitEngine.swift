import Foundation
import CoreMedia
import os
import VLCKitSPM
import ParallaxCore

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
/// **Teardown order (critical):** nil delegate → stop → nil media → finish continuation.
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

    // MARK: - Playback state tracking

    private var currentMedia: VLCMedia?

    // MARK: - Init

    public override init() {
        _ = Self._eventsConfigured   // guarantee main-queue delegate delivery before the player exists
        let (stream, cont) = AsyncStream<PlaybackState>.makeStream()
        self.state = stream
        self.continuation = cont
        self.player = VLCMediaPlayer()
        super.init()
        player.delegate = self
        continuation.yield(.idle)
    }

    // MARK: - PlaybackEngine

    public func load(_ asset: PlayableAsset) async throws {
        continuation.yield(.loading)
        // VLCMedia(url:) returns optional; a nil result means the URL was rejected
        // by libvlc at construction time (e.g. empty path). Treat as unplayable.
        guard let media = VLCMedia(url: asset.url) else {
            continuation.yield(.failed(.assetNotPlayable))
            throw PlaybackError.assetNotPlayable
        }
        applyOptions(to: media, asset: asset)
        currentMedia = media
        player.media = media

        // Resolve and attach external subtitles before playback begins.
        // addPlaybackSlave must run before play() so VLC loads them with the media open.
        let deliveries = SubtitleResolver.resolveAll(
            subtitles: asset.externalSubtitles,
            engine: .vlcKit
        )
        for delivery in deliveries {
            if case .vlcSlave(let url, let enforce) = delivery {
                let result = player.addPlaybackSlave(url, type: .subtitle, enforce: enforce)
                if result != 0 {
                    Log.playback.warning(
                        "VLCKitEngine: addPlaybackSlave returned \(result, privacy: .public) for \(url.lastPathComponent, privacy: .public)"
                    )
                }
            }
        }
    }

    public func play() async {
        player.play()
    }

    public func pause() async {
        player.pause()
        emitPausedIfReady()
    }

    public func seek(to time: CMTime) async {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        let ms = Int32(min(max(seconds * 1000, Double(Int32.min)), Double(Int32.max)))
        player.time = VLCTime(int: ms)
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
            player.deselectAllTextTracks()
            return
        }
        guard let vlcID = track.id.vlcTrackID else { return }
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

    /// Teardown order: nil delegate → stop → nil media → finish continuation.
    public func teardown() async {
        player.delegate = nil
        player.stop()
        player.media = nil
        currentMedia = nil
        continuation.finish()
    }

    // MARK: - Private helpers

    private func applyOptions(to media: VLCMedia, asset: PlayableAsset) {
        media.addOption(":network-caching=3000")
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
    }

    private func emitPausedIfReady() {
        guard let media = currentMedia else { return }
        let posMs = player.time.intValue
        guard posMs >= 0 else { return }
        let durMs = media.length.intValue
        guard durMs > 0 else { return }
        let position = CMTime(value: CMTimeValue(posMs), timescale: 1000)
        let duration = CMTime(value: CMTimeValue(durMs), timescale: 1000)
        continuation.yield(.paused(position: position, duration: duration))
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

    static func vlcTimeToCMTime(ms: Int32) -> CMTime {
        guard ms > 0 else { return .zero }
        return CMTime(value: CMTimeValue(ms), timescale: 1000)
    }

    static func positionState(isPlaying: Bool, positionMs: Int32, durationMs: Int32) -> PlaybackState {
        let position = vlcTimeToCMTime(ms: positionMs)
        let duration = durationMs > 0 ? CMTime(value: CMTimeValue(durationMs), timescale: 1000) : .zero
        return isPlaying ? .playing(position: position, duration: duration) : .paused(position: position, duration: duration)
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

    // MARK: — Time changes (periodic)

    public nonisolated func mediaPlayerTimeChanged(_ aNotification: NSNotification) {
        MainActor.assumeIsolated {
            handleTimeChanged()
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

    // MARK: — Private (MainActor, called via assumeIsolated)

    private func handleStateChanged(_ state: VLCMediaPlayerState) {
        switch state {
        case .opening, .buffering:
            continuation.yield(.loading)
        case .playing:
            handleTimeChanged()
        case .paused:
            emitPausedIfReady()
        case .stopped, .stopping:
            // Emit .ended only when there is a current media (natural end-of-stream).
            // During teardown the delegate is nilled BEFORE player.stop(), so this
            // branch is never reached from teardown — no spurious .ended beat.
            if currentMedia != nil {
                continuation.yield(.ended)
            }
        case .error:
            continuation.yield(.failed(.assetNotPlayable))
        @unknown default:
            break
        }
    }

    private func handleTimeChanged() {
        guard let media = currentMedia else { return }
        let posMs = player.time.intValue       // Int32
        let durMs = media.length.intValue      // Int32
        // durMs is 0 until mediaPlayerLengthChanged fires, so this also prevents a .playing beat landing before .ready.
        guard durMs > 0 else { return }
        // Re-read player.state rather than trusting the delivered event, so a near-simultaneous pause surfaces correctly.
        let isPlaying = player.state == .playing
        continuation.yield(Self.positionState(isPlaying: isPlaying, positionMs: posMs, durationMs: durMs))
    }

    private func handleLengthChanged(_ lengthMs: Int64) {
        guard lengthMs > 0 else { return }
        let inventory = buildTrackInventory()
        let duration = CMTime(value: CMTimeValue(lengthMs), timescale: 1000)
        continuation.yield(.ready(duration: duration, tracks: inventory))
    }
}

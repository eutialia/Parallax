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

        let defaultSub = Self.defaultExternalSubtitle(from: asset.externalSubtitles)
        for sub in asset.externalSubtitles {
            let enforce = (sub.url == defaultSub?.url)
            let result = player.addPlaybackSlave(sub.url, type: .subtitle, enforce: enforce)
            if result != 0 {
                Log.playback.warning(
                    "VLC addPlaybackSlave failed for \(sub.url.lastPathComponent, privacy: .public), result=\(result, privacy: .public)"
                )
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
        // Implemented in Task 5b.5
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) async {
        // Implemented in Task 5b.5
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
        TrackInventory.empty
    }

    /// Call once at process start, before any `VLCMediaPlayer` is created.
    public static func configureVLCEvents() {
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()
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

    public static func defaultExternalSubtitle(
        from subtitles: [ExternalSubtitle]
    ) -> ExternalSubtitle? {
        subtitles.first(where: { $0.isForced }) ?? subtitles.first
    }

    public static func buildAudioTrack(id: String, name: String, language: String?) -> AudioTrack {
        AudioTrack(id: id, displayName: name, languageCode: language)
    }

    public static func buildSubtitleTrack(id: String, name: String, language: String?) -> SubtitleTrack {
        SubtitleTrack(id: id, displayName: name, languageCode: language, isForced: false)
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCKitEngine: VLCMediaPlayerDelegate {
    // Delegate methods implemented in Task 5b.4
}

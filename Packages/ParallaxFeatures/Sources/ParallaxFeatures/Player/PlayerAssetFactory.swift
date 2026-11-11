import Foundation
import ParallaxJellyfin
import ParallaxPlayback

/// Builds the `PlayableAsset` the engine loads.
enum PlayerAssetFactory {
    /// A Jellyfin stream as the server resolved it.
    static func asset(for resolved: ResolvedPlayback) -> PlayableAsset {
        PlayableAsset(
            url: resolved.url,
            // Jellyfin's HLS transcode serves a full-timeline playlist and ignores
            // StartTimeTicks for the offset, so every method resumes by seeking client-side.
            startTime: resolved.startTime,
            mediaStreams: resolved.mediaStreams,
            defaultAudioStreamIndex: resolved.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: resolved.defaultSubtitleStreamIndex,
            engineSubtitlesDisabled: resolved.clientRendersAllSubtitles
        )
    }

    /// A browsed SMB file, resolved by the caller.
    static func asset(for smbItem: SMBPlaybackItem) -> PlayableAsset {
        PlayableAsset(url: smbItem.url, startTime: smbItem.startTime)
    }
}

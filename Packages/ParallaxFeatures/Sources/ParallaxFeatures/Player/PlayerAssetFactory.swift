import Foundation
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback
import ParallaxSubtitles

/// Builds the `PlayableAsset` an engine loads: the delivered stream's hints, the start time it
/// resumes at, and the subtitle look VLC's own renderers draw embedded tracks with.
struct PlayerAssetFactory {
    /// The user's subtitle appearance, read at asset-construction time. A closure rather
    /// than a value: `SubtitlePreferences` loads its persisted style asynchronously, so a
    /// value captured when the view model was built could be the pre-load default.
    /// Sampled once per asset — `:ssa-fontsdir` is a media option read when libvlc builds
    /// the decoder, and the `--freetype-font`/`--freetype-*` look is an instance argument
    /// fixed when the player's library is built. Neither can change under a live player.
    let subtitleStyle: @MainActor () -> SubtitleStyle

    /// The player's surface and the overlay's cue size on it, for the one asset field that
    /// needs a size at load (`EngineSubtitleTextStyle.relativeFontSize`). The app measures
    /// both, and stands in a default surface until the player's geometry has landed — which
    /// normally beats the resolve it races.
    let subtitleSurface: @MainActor () -> SubtitleSurface

    /// VLC's own font directory and freetype family for a subtitle design. The directory is
    /// built in Caches, so it is the app's to provide.
    let engineSubtitleFonts: @Sendable (SubtitleFontBundle.Design) -> EngineSubtitleFonts

    /// The fonts for the user's typeface, and the user's style as VLC's freetype renderer
    /// takes it, sized against the live surface. The style rides every asset so an embedded
    /// SRT the ENGINE draws matches the cue the client renderer draws for an external one.
    private func engineSubtitleLook() -> (fonts: EngineSubtitleFonts, textStyle: EngineSubtitleTextStyle) {
        let style = subtitleStyle()
        let surface = subtitleSurface()
        return (
            engineSubtitleFonts(style.fontDesign.bundleDesign),
            EngineSubtitleTextStyle(
                style: style,
                relativeFontSize: style.freetypeRelativeFontSize(surface: surface.size, cueSize: surface.cueSize)
            )
        )
    }

    /// A Jellyfin stream as the server resolved it.
    func asset(for resolved: ResolvedPlayback) -> PlayableAsset {
        let look = engineSubtitleLook()
        return PlayableAsset(
            url: resolved.url,
            headers: nil,
            hints: Self.deliveredHints(for: resolved),
            // Every method resumes by SEEKING client-side. Jellyfin's HLS transcode
            // serves a full-timeline VOD playlist (position 0 = media start) and
            // ignores StartTimeTicks for the offset, so — exactly like direct-play —
            // the engine must seek to resolved.startTime on .ready. (Was nil for
            // transcode on the false "baked into the URL" assumption, which made
            // every transcode — first-play resume and post-track-switch — restart
            // at 0:00.)
            startTime: resolved.startTime,
            // Authoritative track names/languages — the engine uses these to
            // label tracks a transcode manifest left unnamed. (External subs aren't
            // passed to the engine at all — they're rendered client-side via
            // `PlayerTrackMenus.externalSubtitleTracks` + `SidecarSubtitles`, like the
            // transcode path.)
            mediaStreams: resolved.mediaStreams,
            defaultAudioStreamIndex: resolved.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: resolved.defaultSubtitleStreamIndex,
            // The bundled Noto faces in the user's chosen design, for VLC's text
            // renderers (unused by AVKit): a directory for its internal libass — one
            // that also answers to libass' hardcoded default family, see the app's
            // `VLCSubtitleFonts` — and a family name for its simple freetype renderer.
            subtitleFontsDirectory: look.fonts.directory,
            subtitleFontFamily: look.fonts.family,
            // The same style the client renderer draws external subs with, so a VLC-drawn
            // embedded SRT matches it instead of falling back to freetype's own defaults.
            subtitleTextStyle: look.textStyle,
            // Blind the engine's SPU renderer only when it has NOTHING left to draw:
            // every reported subtitle has a sidecar URL we fetch and render ourselves
            // (`subtitleStreamURLs` covers embedded text streams too). An item with a
            // PGS/VobSub stream keeps the renderer on — there is no sidecar for an
            // image sub, and VLC draws it locally for free. Where it does apply the
            // latch is stronger than a per-pick deselect: VLC keeps discovering text
            // tracks as the demux runs and auto-selects one.
            engineSubtitlesDisabled: resolved.clientRendersAllSubtitles
        )
    }

    /// A browsed SMB file, resolved by the caller.
    func asset(for smbItem: SMBPlaybackItem) -> PlayableAsset {
        let look = engineSubtitleLook()
        return PlayableAsset(
            url: smbItem.url,
            headers: nil,
            // Probe-derived: scheme "http" (+ container/codecs) routes a bridged file to
            // AVKit, scheme "smb" keeps it on VLC. The resolver owns this decision.
            hints: smbItem.hints,
            startTime: smbItem.startTime,
            mediaStreams: [],
            defaultAudioStreamIndex: nil,
            defaultSubtitleStreamIndex: nil,
            // The bundled Noto faces, for VLC's own text renderers. SMB
            // embedded tracks have no extraction endpoint, so the engine keeps
            // rendering them — `engineSubtitlesDisabled` stays false and the
            // per-pick deselect in `activateSidecarSubtitle` handles sidecars.
            subtitleFontsDirectory: look.fonts.directory,
            subtitleFontFamily: look.fonts.family,
            subtitleTextStyle: look.textStyle,
            engineSubtitlesDisabled: false,
            vlcOptions: smbItem.vlcOptions,
            vlcLibraryOptions: smbItem.vlcLibraryOptions
        )
    }

    /// Format hints describing the *delivered* stream the engine selector must
    /// reason about — not necessarily the source. For `.transcode` the server
    /// delivers an HLS stream whose codecs target the AVKit whitelist (per the
    /// device profile), so gating on the source container/codecs (e.g. MKV / AV1
    /// / DTS) would wrongly route an AVKit-playable transcode to VLC and surface
    /// "unsupported format". Direct-play serves the source bytes verbatim, so its
    /// feasibility correctly gates on the source.
    static func deliveredHints(for resolved: ResolvedPlayback) -> PlaybackHints {
        switch resolved.method {
        case .transcode:
            return PlaybackHints(
                scheme: resolved.url.scheme,
                container: .hls,
                videoCodec: nil,
                audioCodecs: [],
                subtitleFormats: []
            )
        case .directPlay:
            return PlaybackHints(
                scheme: resolved.url.scheme,
                container: resolved.container,
                videoCodec: resolved.videoCodec,
                audioCodecs: resolved.audioCodec.map { [$0] } ?? [],
                subtitleFormats: []
            )
        }
    }
}

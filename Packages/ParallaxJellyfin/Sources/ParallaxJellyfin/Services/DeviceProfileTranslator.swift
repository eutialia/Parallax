import Foundation
import JellyfinAPI
import ParallaxCore

/// Translates `DeviceCapabilities` into the Jellyfin SDK wire-format `DeviceProfile`.
///
/// ## Two-tier DirectPlay authoring (Phase 5)
///
/// The profile encodes two direct-play tiers:
///
/// 1. **AVKit tier** — `mp4,mov` containers; `h264,hevc` video; `aac,ac3,eac3,mp3` audio.
///    When a file is in a non-AVKit container (e.g. MKV) but carries an AVKit-compatible
///    video codec, no entry matches → the server remuxes to HLS and the AVKit path
///    handles it (preserving HDR/DV/Atmos).
///
/// 2. **VLC tier** — broad container set; video codecs from `softwareVideoCodecs`
///    (explicitly **excludes** h264/hevc so MKV+HEVC falls through to the AVKit remux);
///    broad audio (all VLC audio, including AVKit audio, because audio breadth is safe
///    once the video-codec gate has already decided AVKit-vs-VLC).
///    Omitted when `softwareVideoCodecs` is empty (avKit-only caps).
///
/// 3. **Transcode floor** — HLS fallback for anything neither tier covers (unchanged).
///
/// ## `hls` divergence (preserved)
///
/// `hls` is NOT in the DirectPlay container strings. It is a transcode delivery format,
/// not a source container. `PlaybackCapabilityMatrix.avKitContainers` retains `.hls` for
/// EngineSelector routing; the translator deliberately subtracts it from BOTH tiers.
enum DeviceProfileTranslator {
    static func deviceProfile(from capabilities: DeviceCapabilities) -> DeviceProfile {
        var directPlayProfiles = [DirectPlayProfile]()

        // 1. AVKit tier — hardware-native direct play
        directPlayProfiles.append(avKitDirectPlay(from: capabilities))

        // 2. VLC tier — software/VLC direct play (omit when no software codecs declared)
        if !capabilities.softwareVideoCodecs.isEmpty {
            directPlayProfiles.append(vlcDirectPlay(from: capabilities))
        }

        // Serialize the device's max bitrate. Sending nil does NOT mean
        // "unlimited" — Jellyfin then applies an 8 Mbps default, which forces a
        // full re-encode (1080p + HDR→SDR tone-map) of any 4K HDR source rather
        // than a stream-copy. With the real ceiling declared, the server copies
        // the bitstream when it fits (verified: a 4K HDR10/PQ HLS variant is
        // offered once the budget ≥ source bitrate). Same value for static
        // (direct-play) and streaming (transcode/remux) so neither path is
        // silently throttled to the default.
        let maxBitrate = Int(capabilities.maxBitrate.rawValue)
        return DeviceProfile(
            codecProfiles: codecProfiles(for: capabilities),
            directPlayProfiles: directPlayProfiles,
            maxStaticBitrate: maxBitrate,
            maxStreamingBitrate: maxBitrate,
            subtitleProfiles: subtitleProfiles(for: capabilities),
            transcodingProfiles: [transcodingProfile()]
        )
    }

    // MARK: — Private: DirectPlay tiers

    private static func avKitDirectPlay(from capabilities: DeviceCapabilities) -> DirectPlayProfile {
        let videoCodecs = capabilities.supportedVideoCodecs
            .map(\.rawValue).sorted().joined(separator: ",")
        let audioCodecs = capabilities.supportedAudioCodecs
            .map(\.rawValue).sorted().joined(separator: ",")
        // Subtract .hls — it is a transcode delivery format, not a direct-play source
        // container. PlaybackCapabilityMatrix.avKitContainers keeps .hls for routing;
        // that must not bleed into the Jellyfin wire profile.
        let containers = Set(capabilities.supportedContainers).subtracting([.hls])
            .map(\.rawValue).sorted().joined(separator: ",")

        return DirectPlayProfile(
            audioCodec: audioCodecs,
            container: containers,
            type: .video,
            videoCodec: videoCodecs
        )
    }

    private static func vlcDirectPlay(from capabilities: DeviceCapabilities) -> DirectPlayProfile {
        // Video: software tier only (h264/hevc excluded by construction in
        // PlaybackCapabilityMatrix.softwareVideoCodecs).
        let videoCodecs = capabilities.softwareVideoCodecs
            .map(\.rawValue).sorted().joined(separator: ",")

        // Audio: union of AVKit audio + VLC-additional audio (the video-codec gate
        // already decided this is a VLC-routed file, so broad audio is safe).
        let allVlcAudio = Set(capabilities.supportedAudioCodecs)
            .union(Set(capabilities.softwareAudioCodecs))
        let audioCodecs = allVlcAudio.map(\.rawValue).sorted().joined(separator: ",")

        // Containers: union of avKit containers + software containers, minus hls
        // (hls is a delivery format, not a direct-play source container).
        let allVlcContainers = Set(capabilities.supportedContainers)
            .union(Set(capabilities.softwareContainers))
            .subtracting([.hls])
        let containers = allVlcContainers.map(\.rawValue).sorted().joined(separator: ",")

        return DirectPlayProfile(
            audioCodec: audioCodecs,
            container: containers,
            type: .video,
            videoCodec: videoCodecs
        )
    }

    // MARK: — Private: Transcode floor

    private static func transcodingProfile() -> TranscodingProfile {
        TranscodingProfile(
            protocol: .hls,
            audioCodec: "aac,ac3,eac3",
            // fMP4, NOT mpegts — even though mpegts would fix the subtitle desync.
            // AVPlayer only decodes HEVC in fMP4; Apple's HLS spec bans HEVC-in-TS, so
            // a `ts` transcode black-screens every HEVC remux/transcode while audio +
            // subs keep playing (verified on device 2026-06-26; cf. Swiftfin#1805). The
            // cost of staying on fMP4 is Jellyfin's `-noaccurate_seek` (jellyfin#15845):
            // a seek that restarts ffmpeg misaligns the transcoded video clock, so the
            // client subtitle overlay (absolute cues vs the player clock) drifts by a
            // fixed, seek-direction-dependent offset until a fresh transcode re-anchors.
            // TS lands seeks frame-accurate (Jellyfin disables `-noaccurate_seek` there)
            // and DID fix the drift on device — but black video rules it out. The
            // subtitle drift is handled above the container, not by switching to TS.
            container: "mp4",
            context: .streaming,
            // Client-side subtitle rendering: we fetch each text subtitle as a
            // sidecar VTT and draw it ourselves through one cross-engine overlay
            // (AVKit + VLC) we fully control — own styling today, user-customizable
            // size/position/color later — so the server must NOT embed a legible
            // group for AVPlayer to auto-select underneath it.
            enableSubtitlesInManifest: false,
            // Startup-latency knobs, matching Swiftfin's native-AVPlayer profile.
            // BreakOnNonKeyFrames matters most on the REMUX path (MKV+HEVC →
            // stream-copy to HLS): with no re-encode the segmenter can't force
            // keyframes, so without this flag every segment cut waits for the
            // source's long-GOP keyframes — the playlist (gated on MinSegments
            // segments existing) takes several GOPs to appear on a 4K movie.
            // AVPlayer handles segments that open mid-GOP.
            // The server marks BreakOnNonKeyFrames [Obsolete] and effectively
            // always-false internally as of 10.9+ (it derives the behavior
            // itself now); kept here for pre-10.9 servers still honoring the
            // client hint — Swiftfin's native-AVPlayer profile does the same.
            isBreakOnNonKeyFrames: true,
            // Request up to 7.1 (8ch) on every transcode. Audio channel layout
            // is output-side: iOS/tvOS hand AVPlayer the full multichannel bed
            // and downmix for the speaker / spatialize for AirPods / re-render
            // on route change — live, free, no re-negotiation. So we never clamp
            // channels to the current route (that would strand a mid-playback
            // headphone switch on a stereo stream); we always deliver the widest
            // bed and let the OS adapt. Without this Jellyfin defaults the
            // transcode to 5.1 and downmixes 7.1 sources.
            maxAudioChannels: "8",
            // Serve the playlist as soon as two segments exist instead of the
            // server's larger default wait — AVPlayer needs about that much to
            // start anyway, so the extra segments only delayed first frame.
            minSegments: 2,
            type: .video,
            videoCodec: "h264,hevc"
        )
    }

    // MARK: — Private: SubtitleProfiles

    private static func subtitleProfiles(for capabilities: DeviceCapabilities) -> [SubtitleProfile] {
        // Text subtitles are delivered EXTERNAL only — never in-manifest. Advertising
        // `vtt/.hls` made the server embed the source's *default* subtitle as an
        // in-manifest WebVTT track on a transcode (even with no subtitle requested);
        // AVPlayer auto-selected and rendered it mis-timed (jellyfin#16647), stacked
        // under our own sidecar overlay and impossible to turn off. With external-only
        // the transcode manifest carries no legible group, and each text sub is fetched
        // as a correctly-timed sidecar VTT (see PlaybackInfoService.subtitleStreamURLs).
        var profiles: [SubtitleProfile] = [
            SubtitleProfile(format: "vtt", method: .external),
            SubtitleProfile(format: "srt", method: .external),
        ]

        // ASS stays external — a text format, fetched + drawn client-side like VTT/SRT.
        profiles.append(SubtitleProfile(format: "ass", method: .external))

        // PGS/VobSub are IMAGE formats — there is no text to hand back as a sidecar
        // VTT, so `.external` could never actually match server-side (it silently
        // fell through to the server's own terminal fallback, which already IS
        // burn-in). Declaring `.encode` makes that explicit: the server renders the
        // subtitle into the video and the client just gets a plain HLS stream with no
        // sub track to select. It's the only way an image sub is ever selectable on
        // the transcode path (PlaybackInfoService/PlayerViewModel gate this behind an
        // explicit user pick — burn-in forces a full re-encode, and can even turn an
        // HDR source SDR server-side; jellyfin-tizen#202 — so it's opt-in, never a
        // default). Direct-play is unaffected: VLC renders PGS/VobSub natively there.
        profiles.append(SubtitleProfile(format: "pgs", method: .encode))
        profiles.append(SubtitleProfile(format: "vobsub", method: .encode))

        return profiles
    }

    // MARK: — Private: CodecProfiles

    private static func codecProfiles(for capabilities: DeviceCapabilities) -> [CodecProfile] {
        // Keep the server from direct-playing a stream the hardware can't decode.
        //
        // H.264: Apple silicon hardware-decodes 8-bit 4:2:0 only. Gate on
        // VideoProfile (the approach Swiftfin's AVKit profile and jellyfin-web
        // both ship): the allowed set excludes "high 10" (10-bit), "high 4:2:2",
        // and "high 4:4:4", so the server transcodes those to HLS rather than
        // serving a stream VideoToolbox rejects (kVTVideoDecoderBadDataErr /
        // -8969 → black video). Profile gating catches the whole undecodable
        // class, not just bit depth.
        //
        // HEVC: 10-bit (Main 10) IS hardware-decodable, so cap on bit depth —
        // 12-bit masters transcode. Gate the profile too: VideoToolbox decodes
        // Main/Main10 only, not the Range Extensions (RExt) or Screen Content
        // Coding (SCC) profiles some encoders emit for 4:4:4/4:2:2 or
        // lossless-leaning masters. Without the profile gate, a RExt/SCC stream
        // still passes the bit-depth check (it's often 8- or 10-bit), the
        // server stream-copies it, and AVPlayer black-screens on the
        // undecodable bitstream — Swiftfin gates the same way. HDR itself is
        // left to the server/AVPlayer tone-mapping path.
        //
        // isRequired:false matches the ecosystem; for a probed stream the
        // condition gates regardless, and false only avoids a needless transcode
        // when the server couldn't read the profile/bit depth.
        //
        // Width/Height cap both video codecs at capabilities.maxResolution —
        // e.g. a source above the device's declared ceiling (4K today) gets
        // downscaled server-side instead of direct-played oversized.
        //
        // VideoRangeType gates which HDR flavours may be DELIVERED AS-IS
        // (direct play / the AVKit remux tier stream-copies the source video).
        // Dolby Vision without a decodable base layer is the killer: a DV remux
        // passes the bit-depth gate as plain HEVC, AVPlayer accepts the manifest,
        // then the video decoder rejects every sample. Profile 7 (`DOVIWithEL`)
        // is never decodable here; the With-HDR10/SDR/HLG variants carry a base
        // layer AVPlayer plays. Anything outside the list (incl. `DOVIInvalid`)
        // transcodes. Profile 5 (`DOVI`, bare — no fallback layer at all) is
        // ALSO never decodable by a base-layer path, but unlike the others it's
        // fine on hardware that can decode Dolby Vision natively — see the
        // conditional append below.
        //
        // The whitelist is otherwise deliberately STATIC — not conditional on
        // probed HDR support: per TN3145 AVPlayer tone-maps HDR optimally on
        // ANY Apple device, so HDR10/HLG are safe to deliver even to an SDR
        // display. Gating them on the probe condemned an Apple TV running its
        // UI in SDR to a server-side 4K tone-map re-encode that couldn't
        // sustain realtime — endless buffering with -12889 segment timeouts
        // (device-diagnosed 2026-06-10, `reason: VideoCodecNotSupported` on
        // plain HDR10 content).
        var hevcRanges = "SDR|HDR10|HDR10Plus|HLG|DOVIWithSDR|DOVIWithHDR10|DOVIWithHDR10Plus|DOVIWithHLG"
        // Bare P5 is the one HDR flavour that DOES need the probe: it has no
        // fallback base layer, so declaring it unconditionally would make the
        // server hand it to hardware that can't decode Dolby Vision at all.
        // `LiveCapabilityProbe.hdrSupport()` only reports `.dolbyVision` when
        // VideoToolbox confirms hardware DV decode — see that file for why the
        // once-standard `AVPlayer.availableHDRModes` check no longer applies
        // (deprecated iOS/tvOS 26). Apple hardware decodes P5 straight out of
        // fMP4, so once declared, the server stream-copies it instead of
        // force-re-encoding the way it does for clients that don't declare DOVI.
        if capabilities.hdr.contains(.dolbyVision) {
            hevcRanges += "|DOVI"
        }

        let resolutionConditions = [
            ProfileCondition(
                condition: .lessThanEqual,
                isRequired: false,
                property: .width,
                value: String(capabilities.maxResolution.width)
            ),
            ProfileCondition(
                condition: .lessThanEqual,
                isRequired: false,
                property: .height,
                value: String(capabilities.maxResolution.height)
            ),
        ]

        return [
            CodecProfile(
                codec: "h264",
                conditions: [
                    ProfileCondition(
                        condition: .equalsAny,
                        isRequired: false,
                        property: .videoProfile,
                        value: "high|main|baseline|constrained baseline"
                    ),
                    // H.264 HDR isn't an AVPlayer thing; DV-on-AVC (profile 9)
                    // only passes with an SDR base. Swiftfin parity.
                    ProfileCondition(
                        condition: .equalsAny,
                        isRequired: false,
                        property: .videoRangeType,
                        value: "SDR|DOVIWithSDR"
                    ),
                ] + resolutionConditions,
                type: .video
            ),
            CodecProfile(
                codec: "hevc",
                conditions: [
                    ProfileCondition(
                        condition: .lessThanEqual,
                        isRequired: false,
                        property: .videoBitDepth,
                        value: "10"
                    ),
                    ProfileCondition(
                        condition: .equalsAny,
                        isRequired: false,
                        property: .videoProfile,
                        value: "main|main10"
                    ),
                    ProfileCondition(
                        condition: .equalsAny,
                        isRequired: false,
                        property: .videoRangeType,
                        value: hevcRanges
                    ),
                ] + resolutionConditions,
                type: .video
            ),
        ]
    }
}

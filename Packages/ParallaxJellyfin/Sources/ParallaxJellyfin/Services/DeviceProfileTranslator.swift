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

        return DeviceProfile(
            codecProfiles: codecProfiles(for: capabilities),
            directPlayProfiles: directPlayProfiles,
            maxStaticBitrate: nil,
            maxStreamingBitrate: nil,
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
            container: "mp4",
            context: .streaming,
            enableSubtitlesInManifest: true,
            type: .video,
            videoCodec: "h264,hevc"
        )
    }

    // MARK: — Private: SubtitleProfiles

    private static func subtitleProfiles(for capabilities: DeviceCapabilities) -> [SubtitleProfile] {
        // AVKit subtitle delivery: VTT in-manifest or as an external sidecar.
        var profiles: [SubtitleProfile] = [
            SubtitleProfile(format: "vtt", method: .hls),
            SubtitleProfile(format: "vtt", method: .external),
            // SRT external: SubtitleResolver delivers sidecar URLs via
            // addPlaybackSlave on VLC; AVKit receives SRT via existing sidecar path.
            SubtitleProfile(format: "srt", method: .external),
        ]

        // VLC subtitle formats — external delivery; VLC parses inline via libass/libavcodec.
        // These tell the server to expose the subtitle stream as an external sidecar URL
        // which SubtitleResolver feeds to addPlaybackSlave.
        profiles.append(SubtitleProfile(format: "ass", method: .external))
        profiles.append(SubtitleProfile(format: "pgs", method: .external))
        profiles.append(SubtitleProfile(format: "vobsub", method: .external))

        return profiles
    }

    // MARK: — Private: CodecProfiles (unchanged from Phase 4)

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
        // 12-bit masters transcode. HDR is left to the server/AVPlayer
        // tone-mapping path; conservative in Phase 4.
        //
        // isRequired:false matches the ecosystem; for a probed stream the
        // condition gates regardless, and false only avoids a needless transcode
        // when the server couldn't read the profile/bit depth.
        [
            CodecProfile(
                codec: "h264",
                conditions: [
                    ProfileCondition(
                        condition: .equalsAny,
                        isRequired: false,
                        property: .videoProfile,
                        value: "high|main|baseline|constrained baseline"
                    ),
                ],
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
                ],
                type: .video
            ),
        ]
    }
}

import Foundation
import JellyfinAPI
import ParallaxCore

/// Translates the lean Core `DeviceCapabilities` into the SDK's wire-format
/// `DeviceProfile`. Hand-authored against Swiftfin's known-good iOS profile —
/// the SDK ships no prebuilt one. Phase 4 advertises only the AVPlayer-playable
/// whitelist for direct play, so the server transcodes everything else to HLS.
/// No client bitrate cap: maxStreamingBitrate / maxStaticBitrate are nil
/// regardless of `capabilities.maxBitrate` (a high sentinel).
enum DeviceProfileTranslator {
    static func deviceProfile(from capabilities: DeviceCapabilities) -> DeviceProfile {
        DeviceProfile(
            codecProfiles: codecProfiles(for: capabilities),
            directPlayProfiles: [
                DirectPlayProfile(
                    audioCodec: "aac,ac3,eac3,mp3",
                    container: "mp4,mov",
                    type: .video,
                    videoCodec: "h264,hevc"
                ),
            ],
            maxStaticBitrate: nil,
            maxStreamingBitrate: nil,
            subtitleProfiles: [
                SubtitleProfile(format: "vtt", method: .hls),
                SubtitleProfile(format: "vtt", method: .external),
            ],
            transcodingProfiles: [
                TranscodingProfile(
                    protocol: .hls,
                    audioCodec: "aac,ac3,eac3",
                    container: "mp4",
                    context: .streaming,
                    enableSubtitlesInManifest: true,
                    type: .video,
                    videoCodec: "h264,hevc"
                ),
            ]
        )
    }

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

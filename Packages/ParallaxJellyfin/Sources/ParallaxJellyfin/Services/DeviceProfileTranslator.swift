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
        // HEVC main/main10 only — bit-depth guard keeps the server from
        // direct-playing a 12-bit master AVPlayer can't decode. HDR is left
        // to the server/AVPlayer tone-mapping path; conservative in Phase 4.
        [
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

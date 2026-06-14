import Foundation

/// Derives short quality labels ("4K", "HDR") from a video stream's dimensions +
/// Jellyfin VideoRangeType. Used on detail hero metadata and in the player.
public enum QualityBadge {
    /// Resolution bucket from pixel dimensions; nil when unknown or below 4K.
    public static func resolution(width: Int?, height: Int?) -> String? {
        let h = height ?? 0, w = width ?? 0
        if h >= 2000 || w >= 3800 { return "4K" }
        return nil
    }

    /// HDR from Jellyfin VideoRangeType; nil for SDR. All HDR flavours collapse to "HDR".
    /// `DOVIInvalid` (corrupt DV metadata) matches via the `DOVI` substring and maps to
    /// `"HDR"` — AVKit cannot deliver it as Dolby Vision.
    public static func hdr(_ videoRangeType: String?) -> String? {
        guard let r = videoRangeType?.uppercased() else { return nil }
        if r.contains("DOVI")
            || r.contains("DOLBY")
            || r.contains("HDR")
            || r.contains("HLG")
        {
            return "HDR"
        }
        return nil
    }

    /// Ordered label list: resolution first, then HDR. Empty when neither is known.
    public static func badges(width: Int?, height: Int?, videoRangeType: String?) -> [String] {
        [resolution(width: width, height: height), hdr(videoRangeType)].compactMap { $0 }
    }
}

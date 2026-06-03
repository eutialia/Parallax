import Foundation

/// Derives short poster badges ("4K", "HDR", "Dolby Vision") from a video stream's
/// dimensions + Jellyfin VideoRangeType. Single source so Movie and Series agree.
public enum QualityBadge {
    /// Resolution bucket from pixel dimensions; nil when unknown or below HD.
    public static func resolution(width: Int?, height: Int?) -> String? {
        let h = height ?? 0, w = width ?? 0
        if h >= 2000 || w >= 3800 { return "4K" }
        if h >= 1400 || w >= 2000 { return "1440p" }
        if h >= 1060 || w >= 1900 { return "1080p" }
        return nil   // don't badge SD/720p — low signal, clutters the poster
    }

    /// HDR flavour from Jellyfin VideoRangeType ("DOVI"/"HDR10"/"HDR10+"/"HLG"); nil for SDR.
    public static func hdr(_ videoRangeType: String?) -> String? {
        guard let r = videoRangeType?.uppercased() else { return nil }
        // "DOVIInvalid" is a DISTINCT VideoRangeType — corrupt/non-conformant DV
        // metadata that AVKit can't deliver as Dolby Vision (it falls back to the
        // HDR10 base layer). Must be excluded BEFORE the substring DOVI match below,
        // or it would mislabel as "Dolby Vision".
        if r == "DOVIINVALID" { return "HDR" }
        if r.contains("DOVI") || r.contains("DOLBY") { return "Dolby Vision" }
        if r.contains("HDR10+") || r.contains("HDR10PLUS") { return "HDR10+" }
        if r.contains("HDR10") { return "HDR10" }
        if r.contains("HDR") { return "HDR" }
        if r.contains("HLG") { return "HLG" }
        return nil
    }

    /// Ordered badge list for a poster: resolution first, then HDR. Empty when neither.
    public static func badges(width: Int?, height: Int?, videoRangeType: String?) -> [String] {
        [resolution(width: width, height: height), hdr(videoRangeType)].compactMap { $0 }
    }
}

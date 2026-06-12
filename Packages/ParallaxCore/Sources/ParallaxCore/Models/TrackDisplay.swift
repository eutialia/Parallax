import Foundation

/// User-facing names for raw stream metadata — language codes, codec
/// identifiers, channel counts. One vocabulary for every surface that labels a
/// track (player menus, chips, debug HUD), so "subrip" reads SRT and "TRUEHD"
/// reads TrueHD everywhere or nowhere.
public enum TrackDisplay {
    /// Localized language name for an ISO code ("eng" → "English"), skipping
    /// the codes that carry no usable language (`und` undetermined, `mis`
    /// uncoded, `zxx` no linguistic content). Handles both Jellyfin's ISO
    /// 639-2 ("eng") and AVFoundation's BCP-47 ("en", "zh-Hant").
    public static func languageName(_ code: String?, locale: Locale = .current) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let lowered = code.lowercased()
        guard lowered != "und", lowered != "mis", lowered != "zxx" else { return nil }
        return locale.localizedString(forLanguageCode: code)
    }

    /// Audio codec → the name a listener knows it by (Apple's labels where one
    /// exists: "Dolby Digital+", not "EAC3"). Unknown codecs fall back to the
    /// uppercased identifier rather than nil — better an honest "DTS" stand-in
    /// than a blank detail line.
    public static func audioCodecName(codec: String?, profile: String? = nil) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "aac": return "AAC"
        case "ac3": return "Dolby Digital"
        case "eac3": return "Dolby Digital+"
        case "truehd": return "TrueHD"
        case "dts":
            // Jellyfin carries the meaningful tier ("DTS-HD MA", "DTS-HD HRA",
            // "DTS:X") in the profile; the bare codec id is just "dts".
            if let profile = profile?.trimmingCharacters(in: .whitespaces),
               profile.uppercased().hasPrefix("DTS") {
                return profile
            }
            return "DTS"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case "mp2": return "MP2"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case let pcm where pcm.hasPrefix("pcm"): return "PCM"
        default: return codec.uppercased()
        }
    }

    /// Subtitle codec → the format name people search their sub files by
    /// ("subrip" → SRT). Covers the image formats too — they're burn-in-only
    /// today, but this helper shouldn't care.
    public static func subtitleFormatName(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "subrip", "srt": return "SRT"
        case "ass": return "ASS"
        case "ssa": return "SSA"
        case "webvtt", "vtt": return "VTT"
        case "mov_text", "tx3g": return "Timed Text"
        case "ttml": return "TTML"
        case "smi", "sami": return "SAMI"
        case "microdvd": return "SUB"
        case let pgs where pgs.contains("pgs"): return "PGS"
        case "dvdsub", "dvd_subtitle", "vobsub": return "VobSub"
        case "dvbsub", "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }

    /// Channel count → layout label ("6" → "5.1"). Nil in, nil out — an
    /// unknown layout earns no pixel.
    public static func channelLayout(_ channels: Int?) -> String? {
        guard let channels else { return nil }
        switch channels {
        case ...1: return "Mono"
        case 2: return "Stereo"
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }
}

/// Language-TAG comparison across metadata dialects: Jellyfin streams carry
/// ISO 639-2 ("eng", and often the bibliographic variants like "fre"/"ger"
/// that muxers write), AVFoundation media options carry BCP-47 ("en", "en-US").
/// Both sides normalize to terminologic alpha-3 before comparing, so
/// "en" == "eng" == ... and region subtags don't break a match.
public enum TrackLanguage {
    /// ISO 639-2 bibliographic → terminologic. ICU (Locale.LanguageCode) does
    /// NOT recognize the B codes (verified: "fre"/"ger"/"chi" → nil), yet
    /// they're what mkvmerge/ffmpeg historically stamp on tracks. This is the
    /// complete, closed set of codes where B differs from T.
    private static let bibliographicToTerminologic: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    /// Alpha-3 form of any 639-1/639-2(B or T)/BCP-47 tag, lowercased; nil for
    /// empty input. Unknown codes pass through lowercased — two
    /// unknown-but-equal tags should still match each other.
    public static func normalized(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        var base = (code.split(separator: "-").first.map(String.init) ?? code).lowercased()
        if let terminologic = bibliographicToTerminologic[base] { base = terminologic }
        let languageCode = Locale.LanguageCode(base)
        return languageCode.identifier(.alpha3)?.lowercased() ?? base
    }

    public static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a = normalized(a), let b = normalized(b) else { return false }
        return a == b
    }
}

public extension MediaStreamInfo {
    /// The menus' SECONDARY detail line — what the track is made of.
    /// Audio: "TrueHD · 7.1". Subtitle: "SRT · External". Nil when nothing is known.
    var trackDetailLabel: String? {
        let parts: [String?]
        switch kind {
        case .audio:
            parts = [TrackDisplay.audioCodecName(codec: codec, profile: profile),
                     TrackDisplay.channelLayout(channels)]
        case .subtitle:
            parts = [TrackDisplay.subtitleFormatName(codec),
                     isExternal ? "External" : "Embedded"]
        case .video, .other:
            return nil
        }
        let resolved = parts.compactMap(\.self)
        return resolved.isEmpty ? nil : resolved.joined(separator: " · ")
    }
}

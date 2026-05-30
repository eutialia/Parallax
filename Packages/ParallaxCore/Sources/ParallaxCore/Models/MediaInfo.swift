import Foundation

public enum Container: String, Sendable, Hashable, Codable, CaseIterable {
    case mp4
    case mov
    case mkv
    case webm
    case ts
    case hls
    case flac
    case mp3
}

public enum VideoCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264
    case hevc
    case av1
    case vp9
    case vc1          // VC-1 (Windows Media Video 9)
    case mpeg2video   // MPEG-2 Video

    public init?(identifier: String) {
        let normalized = identifier.lowercased().replacingOccurrences(of: ".", with: "")
        switch normalized {
        case "h264", "avc", "avc1": self = .h264
        case "hevc", "h265", "hvc1": self = .hevc
        case "av1": self = .av1
        case "vp9": self = .vp9
        case "vc1": self = .vc1
        case "mpeg2video", "mpeg2": self = .mpeg2video
        default: return nil
        }
    }
}

public enum AudioCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case aac
    case ac3
    case eac3
    case flac
    case mp3
    case opus
    case dts
    case trueHD

    public init?(identifier: String) {
        let normalized = identifier.lowercased().replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "aac": self = .aac
        case "ac3": self = .ac3
        case "eac3", "ec3": self = .eac3
        case "flac": self = .flac
        case "mp3": self = .mp3
        case "opus": self = .opus
        case "dts", "dca": self = .dts
        case "truehd": self = .trueHD
        default: return nil
        }
    }
}

public enum ColorSpace: String, Sendable, Hashable, Codable, CaseIterable {
    case sdr
    case hdr10
    case hdr10Plus
    case dolbyVision
}

// OptionSet because a device can support several HDR formats simultaneously
// (e.g., an iPhone 15 Pro supports HDR10, HDR10+, and Dolby Vision).
public struct HDRSupport: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let hdr10 = HDRSupport(rawValue: 1 << 0)
    public static let hdr10Plus = HDRSupport(rawValue: 1 << 1)
    public static let dolbyVision = HDRSupport(rawValue: 1 << 2)

    public static let none: HDRSupport = []
    public static let both: HDRSupport = [.hdr10, .dolbyVision]

    public func includes(_ other: HDRSupport) -> Bool {
        contains(other)
    }
}

public enum SubtitleFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case srt
    case vtt          // WebVTT
    case ass          // Advanced SubStation Alpha (also covers SSA)
    case pgs          // Image-based, Blu-Ray
    case vobsub       // Image-based, DVD
}

public struct Resolution: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let uhd4K = Resolution(width: 3840, height: 2160)
    public static let hd1080p = Resolution(width: 1920, height: 1080)
    public static let hd720p = Resolution(width: 1280, height: 720)
}

public enum AudioOutputCapability: Sendable, Hashable, Codable {
    case stereo
    case multichannel(channelCount: Int)
    case atmos
}

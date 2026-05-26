import Foundation

public struct Bitrate: Sendable, Hashable, Codable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func bitsPerSecond(_ value: Int64) -> Bitrate {
        Bitrate(rawValue: value)
    }

    public static func kilobits(_ value: Int64) -> Bitrate {
        Bitrate(rawValue: value * 1_000)
    }

    public static func megabits(_ value: Int64) -> Bitrate {
        Bitrate(rawValue: value * 1_000_000)
    }

    public static func < (lhs: Bitrate, rhs: Bitrate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func formatted() -> String {
        switch rawValue {
        case 1_000_000...:
            let mbps = Double(rawValue) / 1_000_000
            return mbps == mbps.rounded() ? "\(Int(mbps)) Mbps" : "\(mbps) Mbps"
        case 1_000...:
            let kbps = Double(rawValue) / 1_000
            return kbps == kbps.rounded() ? "\(Int(kbps)) kbps" : "\(kbps) kbps"
        default:
            return "\(rawValue) bps"
        }
    }
}

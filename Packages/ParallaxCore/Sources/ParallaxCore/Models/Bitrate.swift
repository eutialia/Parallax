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

    // Locked to en_US_POSIX so output is deterministic across locales.
    // Wire to a localized FormatStyle at the call site when displaying in UI.
    public func formatted() -> String {
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...1))
            .locale(Locale(identifier: "en_US_POSIX"))

        switch rawValue {
        case 1_000_000...:
            let mbps = Double(rawValue) / 1_000_000
            return "\(mbps.formatted(style)) Mbps"
        case 1_000...:
            let kbps = Double(rawValue) / 1_000
            return "\(kbps.formatted(style)) kbps"
        default:
            return "\(rawValue) bps"
        }
    }
}

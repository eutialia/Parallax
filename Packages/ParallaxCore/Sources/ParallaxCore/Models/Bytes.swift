import Foundation

public struct Bytes: Sendable, Hashable, Codable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Bytes, rhs: Bytes) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // Locked to en_US_POSIX so output is deterministic across locales.
    // Wire to a localized FormatStyle at the call site when displaying in UI.
    public func formatted() -> String {
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...1))
            .locale(Locale(identifier: "en_US_POSIX"))

        let value = Double(rawValue)
        let units: [(Double, String)] = [
            (1_000_000_000_000, "TB"),
            (1_000_000_000, "GB"),
            (1_000_000, "MB"),
            (1_000, "KB"),
        ]

        for (threshold, unit) in units where abs(value) >= threshold {
            return "\((value / threshold).formatted(style)) \(unit)"
        }

        return "\(rawValue) B"
    }
}

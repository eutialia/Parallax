import Foundation

public struct Bytes: Sendable, Hashable, Codable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Bytes, rhs: Bytes) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func formatted() -> String {
        let value = Double(rawValue)

        let units = [
            (1_000_000_000_000, "TB"),
            (1_000_000_000, "GB"),
            (1_000_000, "MB"),
            (1_000, "KB"),
            (1, "B"),
        ]

        for (threshold, unit) in units {
            if abs(value) >= Double(threshold) {
                let divided = value / Double(threshold)
                // Round to 1 decimal place
                let rounded = (divided * 10).rounded() / 10

                // Format the number, removing trailing .0
                let formatter = NumberFormatter()
                formatter.minimumFractionDigits = 0
                formatter.maximumFractionDigits = 1
                let formatted = formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"

                return "\(formatted) \(unit)"
            }
        }

        return "0 B"
    }
}

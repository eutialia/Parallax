import Foundation

/// A media bitrate stored as bits per second. Build it with `.megabits(_:)`.
public struct Bitrate: Sendable, Hashable {
    /// The bitrate in bits per second.
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// A bitrate from megabits per second (×1,000,000).
    public static func megabits(_ value: Int64) -> Bitrate {
        Bitrate(rawValue: value * 1_000_000)
    }
}

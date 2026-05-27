import Foundation

public struct ItemID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

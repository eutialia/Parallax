import Foundation

public struct CollectionID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

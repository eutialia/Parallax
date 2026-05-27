import Foundation

public struct ImageTag: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

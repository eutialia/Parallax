import Foundation

public struct FilePath: Sendable, Hashable, Codable {
    public let components: [String]

    public init(_ raw: String) {
        self.components = raw.split(separator: "/").map(String.init)
    }

    public init(components: [String]) {
        self.components = components
    }

    public var rendered: String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public var parent: FilePath? {
        guard !components.isEmpty else { return nil }
        return FilePath(components: components.dropLast())
    }

    public func appending(_ component: String) -> FilePath {
        FilePath(components: components + [component])
    }
}

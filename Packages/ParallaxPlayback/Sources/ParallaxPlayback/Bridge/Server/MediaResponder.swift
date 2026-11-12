import Foundation
import ParallaxCore

/// What a `LocalMediaServer` serves. The server owns HTTP: the token, methods, ranges, and
/// streaming. A responder only says which bytes a path names.
public protocol MediaResponder: Sendable {
    /// The path, below the server's token, of what a player opens first.
    var entryPath: String { get }

    /// Nil for a path that names nothing, which the server answers with 404. A throw is
    /// answered with 500.
    func resource(at path: String) async throws -> ServedResource?
}

public struct ServedResource: Sendable {
    public let reader: any RandomAccessReading
    public let contentType: String

    public init(reader: any RandomAccessReading, contentType: String) {
        self.reader = reader
        self.contentType = contentType
    }

    public init(_ bytes: Data, contentType: String) {
        self.init(reader: InMemoryRandomAccessReader(data: bytes), contentType: contentType)
    }
}

/// One file, served by byte range under its own name.
public struct FileRangeResponder: MediaResponder {
    public let entryPath: String
    private let resource: ServedResource

    public init(reader: any RandomAccessReading, fileName: String, contentType: String) {
        entryPath = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        resource = ServedResource(reader: reader, contentType: contentType)
    }

    public func resource(at path: String) async -> ServedResource? {
        path == entryPath ? resource : nil
    }
}

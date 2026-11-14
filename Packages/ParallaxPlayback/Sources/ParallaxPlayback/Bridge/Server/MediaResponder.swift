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

    /// What the request log calls the resource at `path`: never a file name. Nil for a path
    /// that names nothing.
    func role(of path: String) -> String?
}

public struct ServedResource: Sendable {
    public enum Body: Sendable {
        /// Bytes that exist before the request, served by range.
        case ranged(any RandomAccessReading)
        /// Bytes made while they are sent, of a length known only at the end. The server calls
        /// the factory once per request that wants the body, and never for `HEAD`.
        case streamed(@Sendable () -> any BodyProducer)
    }

    public let body: Body
    public let contentType: String

    public init(reader: any RandomAccessReading, contentType: String) {
        body = .ranged(reader)
        self.contentType = contentType
    }

    public init(_ bytes: Data, contentType: String) {
        self.init(reader: InMemoryRandomAccessReader(data: bytes), contentType: contentType)
    }

    public init(contentType: String, streaming produce: @escaping @Sendable () -> any BodyProducer) {
        body = .streamed(produce)
        self.contentType = contentType
    }
}

/// One response's body, made piece by piece as the server sends it.
public protocol BodyProducer: Sendable {
    /// The next piece, or nil after the last. Throws when making it failed.
    func next() async throws -> Data?
    /// Stops the making: the client is gone. A `next` waiting then throws `CancellationError`.
    func cancel()

    /// The file's bytes read from the source so far to make the body.
    var bytesFetched: Int { get }
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

    public func role(of path: String) -> String? {
        path == entryPath ? "file" : nil
    }
}

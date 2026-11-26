import Foundation

/// One request a `LocalMediaServer` answered, as the request log keeps it.
public struct RequestRecord: Sendable, CustomStringConvertible {
    public enum Ending: Sendable, Equatable {
        case complete
        /// The client left before the body ended.
        case dropped
        /// Making the body failed after `bytes` of it had gone out.
        case failed(afterBytes: Int, reason: String)

        /// The error by its type and code only: a source's own description may name the file
        /// or the share, and the log is public.
        static func failed(afterBytes bytes: Int, by error: any Error) -> Ending {
            .failed(afterBytes: bytes, reason: "\(type(of: error)) \((error as NSError).code)")
        }
    }

    /// The resource by what it is to the player, never by file name: `file` for a direct
    /// file, the bridge's own name for its playlists and segments.
    public let resource: String
    public let status: Int
    /// From the request head to the first body byte sent. Nil when none was.
    public let firstByte: Duration?
    public let duration: Duration
    public let bytesSent: Int
    /// The file's bytes read from the source to answer it.
    public let bytesFetched: Int
    public let ending: Ending

    public var description: String {
        let first = firstByte.map { "first byte \(Self.milliseconds($0))" } ?? "no body"
        let ended = switch ending {
        case .complete: "complete"
        case .dropped: "dropped by the client"
        case .failed(let bytes, let reason): "failed after \(bytes) bytes: \(reason)"
        }
        return "\(resource) \(status) \(first), \(Self.milliseconds(duration)), \(bytesSent) bytes sent, "
            + "\(bytesFetched) fetched, \(ended)"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }
}

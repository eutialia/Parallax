import Foundation

/// A generated still frame plus the source's duration, read off the same media the
/// thumbnailer already had to open. `Sendable` so it crosses the package→app boundary cleanly
/// (a raw `CGImage` would not). `duration` is nil when the engine couldn't determine the
/// length — the caller falls back (e.g. to file size for an SMB tile).
public struct ThumbnailFrame: Sendable {
    public let data: Data
    public let duration: Duration?

    public init(data: Data, duration: Duration?) {
        self.data = data
        self.duration = duration
    }
}
